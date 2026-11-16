// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightNet

/// Writing commands and reading what comes back.
extension IMAPClient {
    enum Argument {
        /// Protocol text we wrote ourselves: atoms, sets, lists of flags.
        case word(String)
        /// A string from the caller: quoted when it is 7-bit, else a literal.
        case string(String)
        /// A folder's wire path, sent as it is (a literal if it is not 7-bit).
        case mailbox(String)
        case literal(Data)

        /// The bytes on the wire: inline text, or a literal that needs the server's `+` first.
        /// CR, LF and NUL never reach the wire from anything but a literal.
        var wire: (text: String?, literal: Data?) {
            switch self {
            case let .word(word):
                return (IMAPClient.stripped(word), nil)
            case let .string(string), let .mailbox(string):
                let text = IMAPClient.stripped(string)
                let ascii = text.unicodeScalars.allSatisfy(\.isASCII)
                return ascii ? (IMAPClient.quoted(text), nil) : (nil, Data(text.utf8))
            case let .literal(data):
                return (nil, data)
            }
        }
    }

    struct Completion {
        var kind: StatusKind
        var code: String?
        var text: String
        var untagged: [IMAPResponse]
    }

    var currentTag: String { "A" + String(tagNumber).leftPadded(to: 4) }

    func nextTag() -> String {
        tagNumber &+= 1
        return currentTag
    }

    /// Waits for the turn on the connection; false, without the turn, when the task is
    /// cancelled before it comes.
    func acquire() async -> Bool {
        await acquire(cancellable: true)
    }

    /// As `acquire()`; with `cancellable` false the wait goes on through a cancel and always ends
    /// with the turn.
    func acquire(cancellable: Bool) async -> Bool {
        guard busy else {
            busy = true
            return true
        }
        guard cancellable else {
            return await withCheckedContinuation { waiting.append((nil, $0)) }
        }
        guard !Task.isCancelled else {
            return false
        }
        let id = nextWaiter
        nextWaiter &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { await self.giveUpTurn(id) }
        }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().turn.resume(returning: true)
        }
    }

    private func giveUpTurn(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiting.remove(at: index).turn.resume(returning: false)
    }

    func greet(security: TransportSecurity) async throws(IMAPError) {
        guard case let .status(nil, kind, code, text) = try await readResponse(budget: nil).response else {
            throw .protocolViolation
        }
        switch kind {
        case .ok:
            break
        case .preauth:
            // Already signed in: STARTTLS is no longer allowed, so a required one cannot happen.
            guard security != .startTLS else {
                throw .startTLSNotOffered
            }
        case .bye:
            throw .no(IMAPError.clamp(text))
        case .no, .bad:
            throw .protocolViolation
        }
        try await refreshCapabilities(from: code)
        guard security == .startTLS else {
            return
        }
        guard capabilities.contains("STARTTLS") else {
            throw .startTLSNotOffered
        }
        _ = try await run([.word("STARTTLS")])
        do {
            try await connection.startTLS()
        } catch {
            throw .net(error)
        }
        capabilities = []
        try await refreshCapabilities(from: nil)
    }

    /// Takes capabilities from a `[CAPABILITY ...]` code (already seen by `observe`), or asks.
    func refreshCapabilities(from code: String?) async throws(IMAPError) {
        if let code, Self.capabilities(fromCode: code) != nil {
            return
        }
        _ = try await run([.word("CAPABILITY")])
    }

    static func capabilities(fromCode code: String) -> Set<String>? {
        let words = code.split(separator: " ")
        guard words.first?.uppercased() == "CAPABILITY" else {
            return nil
        }
        return Set(words.dropFirst().map { $0.uppercased() })
    }

    func observe(_ response: IMAPResponse) {
        switch response {
        case let .data(nil, "CAPABILITY", values):
            capabilities = Set(values.compactMap(\.text).map { $0.uppercased() })
        case let .status(_, _, code?, _):
            if let found = Self.capabilities(fromCode: code) {
                capabilities = found
            }
        default:
            break
        }
    }

    /// Runs a command and throws on NO and BAD.
    func run(_ arguments: [Argument]) async throws(IMAPError) -> Completion {
        let completion = try await execute(arguments)
        guard completion.kind == .ok else {
            throw Self.failure(completion.kind, completion.text, code: completion.code)
        }
        return completion
    }

    /// Runs a command and returns how it ended, NO and BAD included.
    func execute(_ arguments: [Argument]) async throws(IMAPError) -> Completion {
        let tag = nextTag()
        var collected = Collected()
        let pieces = Self.pieces(tag: tag, arguments)
        for (index, piece) in pieces.enumerated() {
            try await write(piece)
            let last = index == pieces.count - 1
            if let completion = try await responses(until: tag, continuation: !last, into: &collected) {
                return completion
            }
        }
        throw .protocolViolation
    }

    /// The command in pieces: each but the last ends with a literal's `{n}` and CR LF, and the
    /// next starts with that literal's bytes.
    static func pieces(tag: String, _ arguments: [Argument]) -> [Data] {
        var pieces: [Data] = []
        var line = Data(tag.utf8)
        for argument in arguments {
            line.append(UInt8(ascii: " "))
            let wire = argument.wire
            if let text = wire.text {
                line.append(Data(text.utf8))
            } else if let literal = wire.literal {
                line.append(Data("{\(literal.count)}\r\n".utf8))
                pieces.append(line)
                line = literal
            }
        }
        line.append(Data("\r\n".utf8))
        pieces.append(line)
        return pieces
    }

    /// What one command has brought back so far, and how many bytes that took.
    struct Collected {
        var untagged: [IMAPResponse] = []
        var bytes = 0
    }

    /// Reads until the command tagged `tag` ends, collecting untagged responses, at most
    /// 128 MiB of them for one command. With `continuation`, a `+` also ends the wait, and nil
    /// is returned.
    func responses(
        until tag: String,
        continuation: Bool,
        into collected: inout Collected
    ) async throws(IMAPError) -> Completion? {
        while true {
            let (response, bytes) = try await readResponse(budget: nil)
            collected.bytes = collected.bytes.saturatingAdd(bytes)
            guard collected.bytes <= timing.commandTotal else {
                throw .protocolViolation
            }
            switch response {
            case .continuation where continuation:
                return nil
            case let .status(responseTag?, kind, code, text) where responseTag == tag:
                return Completion(kind: kind, code: code, text: IMAPError.clamp(text), untagged: collected.untagged)
            case .status(_?, _, _, _), .continuation:
                throw .protocolViolation
            default:
                guard collected.untagged.count < Self.maxUntagged else {
                    throw .protocolViolation
                }
                collected.untagged.append(response)
            }
        }
    }

    func search(_ keys: [Argument]) async throws(IMAPError) -> [UInt32] {
        let completion = try await run([.word("UID SEARCH")] + keys)
        var found: Set<UInt32> = []
        for case let .data(nil, "SEARCH", values) in completion.untagged {
            found.formUnion(values.compactMap(\.number))
        }
        return found.sorted()
    }

    func write(_ data: Data) async throws(IMAPError) {
        do {
            try await connection.write(data)
        } catch {
            throw .net(error)
        }
    }

    /// Reads one response with its literals, every size bounded, within `budget` (the
    /// timing's response time when nil) plus time for its literals. Returns its size on the
    /// wire too.
    func readResponse(budget: Duration?) async throws(IMAPError) -> (response: IMAPResponse, bytes: Int) {
        // A long wait (IDLE) waits as long for each piece; anything else gives up on a silent
        // server after the per-read time.
        let perRead = budget.map { max($0, timing.perRead) } ?? timing.perRead
        let budget = budget ?? timing.response
        var deadline = ContinuousClock.now + budget
        var raw = Data()
        var literals = 0
        var first = true
        var allowsLiterals = true
        while true {
            let line: Data
            do {
                line = try await connection.readLine(timeout: perRead, deadline: deadline)
            } catch {
                throw .net(error)
            }
            raw.append(line)
            if first {
                allowsLiterals = IMAPParser.allowsLiterals(firstLine: line)
                first = false
            }
            guard allowsLiterals, let length = try IMAPParser.literalLength(atEndOf: line) else {
                break
            }
            literals += 1
            guard literals <= Self.maxLiterals, raw.count.saturatingAdd(length) <= Self.maxResponse else {
                throw .protocolViolation
            }
            deadline += .seconds(length / max(1, timing.literalBytesPerSecond) + 1)
            raw.append(Data("\r\n".utf8))
            do {
                raw.append(try await connection.read(exactly: length, deadline: deadline))
            } catch {
                throw .net(error)
            }
        }
        let response = try IMAPParser.parse(raw)
        observe(response)
        // The size on the wire: the last line's CR LF too (the others' are in `raw`).
        return (response, raw.count.saturatingAdd(2))
    }
}

extension Int {
    func saturatingAdd(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
