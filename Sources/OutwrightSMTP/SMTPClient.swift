// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightMIME
public import OutwrightNet

/// Submits one message (RFC 5321, AUTH by RFC 4954, STARTTLS by RFC 3207, TLS by RFC 8314).
public enum SMTPClient {
    static let maxMessage = 64 << 20
    static let maxReplyLines = 100
    static let maxLine = 4096
    static let maxText = 200
    /// Longest address a path takes (RFC 5321's 256, less its brackets).
    static let maxPath = 254

    // swiftlint:disable:next function_parameter_count
    public static func send(
        _ message: Data,
        envelopeFrom: String,
        recipients: [String],
        via endpoint: ServerEndpoint,
        user: String,
        password: Secret
    ) async throws(SMTPError) {
        try await send(
            message, envelopeFrom: envelopeFrom, recipients: recipients, via: endpoint, user: user,
            credential: .password(password))
    }

    /// As `send(_:envelopeFrom:recipients:via:user:password:)`, signing in with a password or
    /// an OAuth access token.
    public static func send( // swiftlint:disable:this function_parameter_count
        _ message: Data,
        envelopeFrom: String,
        recipients: [String],
        via endpoint: ServerEndpoint,
        user: String,
        credential: SMTPCredential
    ) async throws(SMTPError) {
        guard !recipients.isEmpty else {
            throw .noRecipients
        }
        // Dropping one would send the message to fewer people than the owner asked for; one too long
        // for a path, or with a domain that has no ASCII form, no server takes.
        let to = recipients.compactMap { MailAddress.ascii(address($0)) }
        guard to.count == recipients.count, !to.contains(where: { $0.isEmpty || $0.utf8.count > maxPath }),
              let from = MailAddress.ascii(address(envelopeFrom))
        else {
            throw .invalidRecipient
        }
        guard message.count <= maxMessage else {
            throw .rejected(code: 552, text: "message too large")
        }
        let wire = Wire(connection: try await open(endpoint))
        do {
            let job = Job(
                message: message, from: from, to: to, endpoint: endpoint,
                needsUTF8: !([from] + to).allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }
                    || headersAreNotASCII(message))
            try await submit(wire, job, user: user, credential: credential)
        } catch {
            await wire.connection.close()
            throw error
        }
        await wire.connection.close()
    }

    /// Connects and signs in, then says goodbye without sending anything: whether the server
    /// takes these credentials (an account being added).
    public static func signIn(via endpoint: ServerEndpoint, user: String, password: Secret) async throws(SMTPError) {
        try await signIn(via: endpoint, user: user, credential: .password(password))
    }

    /// As `signIn(via:user:password:)`, with a password or an OAuth access token.
    public static func signIn(
        via endpoint: ServerEndpoint, user: String, credential: SMTPCredential
    ) async throws(SMTPError) {
        let wire = Wire(connection: try await open(endpoint))
        do {
            try await handshake(wire, endpoint: endpoint, user: user, credential: credential)
            try? await wire.send("QUIT")
        } catch {
            await wire.connection.close()
            throw error
        }
        await wire.connection.close()
    }

    private static func open(_ endpoint: ServerEndpoint) async throws(SMTPError) -> LineConnection {
        do {
            return try await LineConnection.open(endpoint)
        } catch {
            throw .net(error)
        }
    }

    private struct Job {
        var message: Data
        var from: String
        var to: [String]
        var endpoint: ServerEndpoint
        /// An address or a header is not ASCII: the message goes only with SMTPUTF8 (RFC 6531).
        var needsUTF8: Bool
    }

    /// Whether the header section (up to the first empty line) holds a byte that is not ASCII:
    /// UTF-8 headers (RFC 6532), which only a server with SMTPUTF8 takes.
    static func headersAreNotASCII(_ message: Data) -> Bool {
        var previous: UInt8?
        for byte in message {
            if byte >= 0x80 {
                return true
            }
            if byte == 10, previous == 10 {
                return false
            }
            if byte != 13 {
                previous = byte
            }
        }
        return false
    }

    private static func submit(
        _ wire: Wire, _ job: Job, user: String, credential: SMTPCredential
    ) async throws(SMTPError) {
        let (message, from, to) = (job.message, job.from, job.to)
        let features = try await handshake(wire, endpoint: job.endpoint, user: user, credential: credential)
        guard !job.needsUTF8 || features.contains("SMTPUTF8") else {
            try? await wire.send("QUIT")
            throw .smtpUTF8NotOffered
        }
        try await wire.send("MAIL FROM:<\(from)>" + (job.needsUTF8 ? " SMTPUTF8" : ""))
        try await expect(wire, 250)
        for recipient in to {
            try await wire.send("RCPT TO:<\(recipient)>")
            let reply = try await wire.reply()
            guard reply.code == 250 || reply.code == 251 else {
                throw .recipientRejected(code: reply.code, text: text(of: reply))
            }
        }
        try await wire.send("DATA")
        try await expect(wire, 354)
        do {
            try await wire.connection.write(stuffed(message))
        } catch {
            throw .net(error)
        }
        try await expect(wire, 250)
        try? await wire.send("QUIT")
    }

    /// Greeting, EHLO, the required STARTTLS, and AUTH: no credential before the encryption asked
    /// for. The features EHLO offered last.
    @discardableResult
    private static func handshake(
        _ wire: Wire, endpoint: ServerEndpoint, user: String, credential: SMTPCredential
    ) async throws(SMTPError) -> Set<String> {
        try await expectSession(wire, 220)
        var features = try await ehlo(wire)
        if endpoint.security == .startTLS {
            guard features.contains("STARTTLS") else {
                throw .startTLSNotOffered
            }
            try await wire.send("STARTTLS")
            try await expectSession(wire, 220)
            do {
                try await wire.connection.startTLS()
            } catch {
                throw .net(error)
            }
            features = try await ehlo(wire)
        }
        switch credential {
        case let .password(password):
            try await authenticate(wire, features: features, user: user, password: password)
        case let .accessToken(token):
            try await authenticate(wire, features: features, user: user, accessToken: token)
        }
        return features
    }

    private static func ehlo(_ wire: Wire) async throws(SMTPError) -> Set<String> {
        try await wire.send("EHLO outwright.invalid")
        let reply = try await wire.reply()
        guard reply.code == 250 else {
            throw .sessionRefused(code: reply.code, text: text(of: reply))
        }
        return Set(reply.lines.map { $0.uppercased() })
    }

    private static func authenticate(
        _ wire: Wire, features: Set<String>, user: String, password: Secret
    ) async throws(SMTPError) {
        let methods = authMethods(features)
        // Both go base64-encoded, so CR and LF are sent as they are; a NUL can't be (it ends a
        // field of AUTH PLAIN), and a changed password is never sent in its place.
        let name = user, secret = password.reveal()
        guard !name.unicodeScalars.contains("\0"), !secret.unicodeScalars.contains("\0") else {
            throw .authenticationFailed
        }
        if methods.contains("PLAIN") {
            let token = Data("\0\(name)\0\(secret)".utf8).base64EncodedString()
            try await wire.send("AUTH PLAIN \(token)")
            try await expectAuth(wire, 235)
        } else if methods.contains("LOGIN") {
            try await wire.send("AUTH LOGIN")
            try await expectAuth(wire, 334)
            try await wire.send(Data(name.utf8).base64EncodedString())
            try await expectAuth(wire, 334)
            try await wire.send(Data(secret.utf8).base64EncodedString())
            try await expectAuth(wire, 235)
        } else {
            throw .authenticationFailed
        }
    }

    /// The AUTH methods EHLO offered: servers may list them over more than one line (`AUTH=` for
    /// old clients), and every line counts.
    static func authMethods(_ features: Set<String>) -> Set<String> {
        Set(features.filter { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }
            .flatMap { $0.dropFirst(5).split(whereSeparator: { $0 == " " }).map(String.init) })
    }

    private static func expectAuth(_ wire: Wire, _ code: Int) async throws(SMTPError) {
        let reply = try await wire.reply()
        if reply.code == code {
            return
        }
        if reply.code == 535 || reply.code == 534 || reply.code == 538 || reply.code == 454 {
            throw .authenticationFailed
        }
        // The server's words after a credential may repeat it; never pass them on.
        throw .rejected(code: reply.code, text: "")
    }

    private static func expect(_ wire: Wire, _ codes: Int...) async throws(SMTPError) {
        let reply = try await wire.reply()
        guard codes.contains(reply.code) else {
            throw rejection(reply)
        }
    }

    /// A reply other than `code` before any of the message is sent: the session is refused.
    private static func expectSession(_ wire: Wire, _ code: Int) async throws(SMTPError) {
        let reply = try await wire.reply()
        guard reply.code == code else {
            throw .sessionRefused(code: reply.code, text: text(of: reply))
        }
    }

    private static func rejection(_ reply: Reply) -> SMTPError {
        .rejected(code: reply.code, text: text(of: reply))
    }

    private static func text(of reply: Reply) -> String {
        String(reply.lines.joined(separator: " ").prefix(maxText))
    }

    /// CR, LF and NUL removed from anything written as a protocol argument.
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" }))
    }

    /// An address fit for a path: no CR, LF or NUL, and outside a quoted local part (RFC 5321
    /// section 4.1.2) no angle brackets or white space.
    static func address(_ text: String) -> String {
        MailAddress.addrSpec(sanitized(text), alsoDrop: ["<", ">"])
    }

    /// The message with every line ending as CR LF, lines that start with a dot doubled, a
    /// final CR LF if missing, and the closing dot line.
    static func stuffed(_ message: Data) -> Data {
        var out = Data()
        out.reserveCapacity(message.count + message.count / 40 + 8)
        var atLineStart = true
        var previousCR = false
        for byte in message {
            if byte == 10 {
                if !previousCR {
                    out.append(13)
                }
                out.append(10)
                atLineStart = true
                previousCR = false
                continue
            }
            if atLineStart, byte == UInt8(ascii: ".") {
                out.append(byte)
            }
            out.append(byte)
            atLineStart = false
            previousCR = byte == 13
        }
        if !atLineStart {
            out.append(contentsOf: [13, 10])
        }
        out.append(contentsOf: Array(".\r\n".utf8))
        return out
    }
}

struct Reply {
    var code: Int
    var lines: [String]
}

struct Wire {
    let connection: LineConnection

    func send(_ line: String) async throws(SMTPError) {
        do {
            try await connection.write(Data((SMTPClient.sanitized(line) + "\r\n").utf8))
        } catch {
            throw .net(error)
        }
    }

    /// One reply, read to its final line; `250-` lines continue it. Bounded in lines and length.
    func reply() async throws(SMTPError) -> Reply {
        var lines: [String] = []
        for _ in 0..<SMTPClient.maxReplyLines {
            let raw: Data
            do {
                raw = try await connection.readLine(maxBytes: SMTPClient.maxLine)
            } catch {
                throw .net(error)
            }
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: raw, as: UTF8.self)
            let digits = Array(text.utf8.prefix(3))
            guard digits.count == 3, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let code = Int(String(text.prefix(3)))
            else {
                throw .net(.io("malformed reply"))
            }
            let rest = text.dropFirst(3)
            lines.append(String(rest.dropFirst().prefix(SMTPClient.maxText)))
            if rest.first != "-" {
                return Reply(code: code, lines: lines)
            }
        }
        throw .net(.lineTooLong)
    }
}
