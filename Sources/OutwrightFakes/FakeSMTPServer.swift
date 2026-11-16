// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// An in-process SMTP submission server on 127.0.0.1 for tests: plain transport, one account
/// (`jk@example.org`, password `secret`), AUTH PLAIN and LOGIN, and XOAUTH2 once given a
/// token with `acceptToken`. STARTTLS can be advertised but is always refused: the fake has
/// no certificate.
public actor FakeSMTPServer {
    let offersStartTLS: Bool
    let offersSMTPUTF8: Bool
    var rejectRecipient: String?
    let rejectCode: Int
    var listener: FakeListener?
    var open: [FakeConnection] = []
    public internal(set) var authAttempts = 0
    /// The access token accepted for each address over XOAUTH2; none: XOAUTH2 not offered.
    var oauthTokens: [String: String] = [:]
    public internal(set) var tokenAttempts: [FakeTokenAttempt] = []
    var acceptedPassword = FakeSMTPServer.password
    var ehloLines: [String]?
    var greeting: [String]?
    // swiftlint:disable:next large_tuple
    public internal(set) var received: [(from: String, to: [String], data: Data)] = []
    /// What followed the path of each `MAIL FROM`, such as `SMTPUTF8`; empty when nothing did.
    public internal(set) var mailParameters: [String] = []
    /// Recipients refused once, with the code, the next time they are offered.
    var refusedOnce: [String: Int] = [:]

    let acceptDelay: Duration
    let greetingCode: Int
    let ehloCode: Int

    /// `rejectRecipient` is refused with `rejectCode` (550: for good; 450: try again later).
    /// `acceptDelay`: how long the server waits after a message's data before it takes it (a
    /// test's window for something to happen while a send is under way). `greetingCode` and
    /// `ehloCode` other than 220 and 250 refuse the session itself, before any message.
    /// `offersSMTPUTF8`: EHLO offers SMTPUTF8 (RFC 6531).
    public init(
        offersStartTLS: Bool = false, offersSMTPUTF8: Bool = false,
        rejectRecipient: String? = nil, rejectCode: Int = 550,
        acceptDelay: Duration = .zero, greetingCode: Int = 220, ehloCode: Int = 250
    ) {
        self.offersStartTLS = offersStartTLS
        self.offersSMTPUTF8 = offersSMTPUTF8
        self.rejectRecipient = rejectRecipient
        self.rejectCode = rejectCode
        self.acceptDelay = acceptDelay
        self.greetingCode = greetingCode
        self.ehloCode = ehloCode
    }

    public func start() async throws -> UInt16 {
        let listener = FakeListener { [weak self] connection in
            await self?.serve(connection)
        }
        self.listener = listener
        return try await listener.start()
    }

    public func stop() {
        listener?.stop()
        for connection in open {
            connection.close()
        }
        open = []
    }

    // MARK: - Serving

    private func serve(_ connection: FakeConnection) async {
        open.append(connection)
        if let greeting {
            for line in greeting {
                connection.send(Self.line(line))
            }
        } else {
            let usual = greetingCode == 220 ? "220 fake.example ESMTP ready" : "\(greetingCode) No service"
            connection.send(Self.line(usual))
        }
        var envelope = Envelope()
        while let raw = await connection.readLine(maxBytes: 4096) {
            if await handle(fakeText(raw), connection, &envelope) == .close {
                break
            }
        }
        connection.close()
        open.removeAll { $0 === connection }
    }

    private struct Envelope {
        var from: String?
        var to: [String] = []
    }

    /// A recipient is taken, or refused (once, or always, as the test set).
    private func offer(_ recipient: String, to envelope: inout Envelope, _ connection: FakeConnection) {
        if let code = refusedOnce.removeValue(forKey: recipient) {
            connection.send(Self.line("\(code) 4.2.0 Try later"))
        } else if recipient == rejectRecipient {
            let text = rejectCode >= 500 ? "5.1.1 No such mailbox" : "4.2.0 Try later"
            connection.send(Self.line("\(rejectCode) \(text)"))
        } else {
            envelope.to.append(recipient)
            connection.send(Self.line("250 OK"))
        }
    }

    private enum Outcome {
        case keepOpen, close
    }

    private func handle(_ text: String, _ connection: FakeConnection, _ envelope: inout Envelope) async -> Outcome {
        let upper = text.uppercased()
        if upper.hasPrefix("EHLO") {
            greet(connection)
        } else if upper.hasPrefix("AUTH ") {
            await authenticate(text, connection)
        } else if upper == "STARTTLS" {
            connection.send(Self.line(offersStartTLS ? "454 The fake has no certificate" : "502 Not offered"))
        } else if upper.hasPrefix("MAIL FROM:") {
            envelope = Envelope(from: Self.path(text.dropFirst(10)))
            mailParameters.append(Self.parameters(text.dropFirst(10)))
            connection.send(Self.line("250 OK"))
        } else if upper.hasPrefix("RCPT TO:") {
            offer(Self.path(text.dropFirst(8)), to: &envelope, connection)
        } else if upper == "DATA" {
            connection.send(Self.line("354 Go ahead"))
            guard let data = await readData(connection) else {
                return .close
            }
            if acceptDelay > .zero {
                try? await Task.sleep(for: acceptDelay)
            }
            received.append((envelope.from ?? "", envelope.to, data))
            connection.send(Self.line("250 Queued"))
        } else if upper == "QUIT" {
            connection.send(Self.line("221 Bye"))
            return .close
        } else {
            connection.send(Self.line(upper == "RSET" || upper == "NOOP" ? "250 OK" : "500 Unknown command"))
        }
        return .keepOpen
    }

    private func greet(_ connection: FakeConnection) {
        guard ehloCode == 250 else {
            connection.send(Self.line("\(ehloCode) Not now"))
            return
        }
        var lines = ehloLines
            ?? ["fake.example", oauthTokens.isEmpty ? "AUTH PLAIN LOGIN" : "AUTH PLAIN LOGIN XOAUTH2", "8BITMIME"]
        if offersStartTLS {
            lines.append("STARTTLS")
        }
        if offersSMTPUTF8 {
            lines.append("SMTPUTF8")
        }
        for (index, line) in lines.enumerated() {
            connection.send(Self.line("250\(index == lines.count - 1 ? " " : "-")\(line)"))
        }
    }

    /// Accepts this access token for the address over `AUTH XOAUTH2` (replacing any earlier
    /// one) and offers XOAUTH2 from now on.
    public func acceptToken(_ token: String, for address: String = FakeSMTPServer.user) {
        oauthTokens[address] = token
    }

    private func authenticate(_ text: String, _ connection: FakeConnection) async {
        authAttempts += 1
        var accepted = false
        if text.uppercased().hasPrefix("AUTH XOAUTH2"), !oauthTokens.isEmpty {
            await authenticateWithToken(text.dropFirst(12).trimmingCharacters(in: .whitespaces), connection)
            return
        }
        if text.uppercased().hasPrefix("AUTH PLAIN") {
            let token = text.dropFirst(10).trimmingCharacters(in: .whitespaces)
            accepted = Self.decode(token) == "\0\(Self.user)\0\(acceptedPassword)"
        } else if text.uppercased() == "AUTH LOGIN" {
            connection.send(Self.line("334 VXNlcm5hbWU6"))
            let name = await connection.readLine(maxBytes: 4096).flatMap { Self.decode(fakeText($0)) }
            connection.send(Self.line("334 UGFzc3dvcmQ6"))
            let word = await connection.readLine(maxBytes: 4096).flatMap { Self.decode(fakeText($0)) }
            accepted = name == Self.user && word == acceptedPassword
        }
        connection.send(Self.line(accepted ? "235 Authenticated" : "535 Authentication failed"))
    }

    /// A refused token gets the base64 JSON challenge, then 535 once the client answers it.
    private func authenticateWithToken(_ initial: String, _ connection: FakeConnection) async {
        var response = initial
        if response.isEmpty {
            connection.send(Self.line("334 "))
            response = await connection.readLine(maxBytes: 4096).map { fakeText($0) } ?? ""
        }
        let decoded = FakeXOAuth2.decode(response)
        let accepted = decoded.map { oauthTokens[$0.user] == $0.token } ?? false
        tokenAttempts.append(
            FakeTokenAttempt(user: decoded?.user ?? "", accepted: accepted, initialResponse: !initial.isEmpty))
        guard accepted else {
            connection.send(Self.line("334 \(FakeXOAuth2.errorChallenge)"))
            _ = await connection.readLine(maxBytes: 4096)
            connection.send(Self.line("535 5.7.3 Authentication unsuccessful"))
            return
        }
        connection.send(Self.line("235 2.7.0 Authentication successful"))
    }

    /// Lines up to the lone dot, with leading dots undone, each ended by CR LF.
    private func readData(_ connection: FakeConnection) async -> Data? {
        var data = Data()
        while let line = await connection.readLine(maxBytes: 1 << 20) {
            if line == Data(".".utf8) {
                return data
            }
            data.append(line.first == UInt8(ascii: ".") ? line.dropFirst() : line[...])
            data.append(contentsOf: [13, 10])
            if data.count > 64 << 20 {
                return nil
            }
        }
        return nil
    }

    public static let user = "jk@example.org"
    public static let password = "secret"

    private static func line(_ text: String) -> Data {
        Data((text + "\r\n").utf8)
    }

    private static func decode(_ base64: String) -> String? {
        Data(base64Encoded: base64).map { fakeText($0) }
    }

    /// What follows the path's closing bracket, trimmed.
    private static func parameters(_ text: Substring) -> String {
        guard let close = text.lastIndex(of: ">") else {
            return ""
        }
        return text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// The address inside `<...>`.
    private static func path(_ text: Substring) -> String {
        guard let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return String(text[text.index(after: open)..<close])
    }
}
