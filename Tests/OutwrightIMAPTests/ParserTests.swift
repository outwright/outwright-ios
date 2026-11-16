// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightIMAP

@Suite struct ParserTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesLiteralsAndQuotedStrings() throws {
        let raw = bytes("* 3 FETCH (UID 42 FLAGS (\\Seen $Label1) INTERNALDATE \"06-Nov-2026 10:00:00 +0100\" ")
            + bytes("RFC822.SIZE 12 BODY[HEADER] {12}\r\nSubject: x\r\n BODY[TEXT]<0> \"a \\\"q\\\" b\")")
        let response = try IMAPParser.parse(raw)
        guard case let .data(number, keyword, values) = response else {
            Issue.record("not data: \(response)")
            return
        }
        #expect(number == 3)
        #expect(keyword == "FETCH")
        let summary = try #require(FetchItems(values).summary())
        #expect(summary.uid == 42)
        #expect(summary.flags == ["\\Seen", "$Label1"])
        #expect(summary.size == 12)
        #expect(summary.headers == bytes("Subject: x\r\n"))
        #expect(summary.partialText == bytes("a \"q\" b"))
        #expect(summary.internalDate == Date(timeIntervalSince1970: 1_793_955_600))
    }

    @Test func rejectsOversizedLiteral() throws {
        #expect(throws: IMAPError.protocolViolation) {
            _ = try IMAPParser.literalLength(atEndOf: self.bytes("* 1 FETCH (BODY[] {70000000}"))
        }
        #expect(throws: IMAPError.protocolViolation) {
            _ = try IMAPParser.parse(self.bytes("* 1 FETCH (BODY[] {70000000}\r\nshort)"))
        }
        #expect(throws: IMAPError.protocolViolation) {
            _ = try IMAPParser.parse(self.bytes("* 1 FETCH (BODY[] {20}\r\nshort)"))
        }
        #expect(try IMAPParser.literalLength(atEndOf: bytes("* 1 FETCH (BODY[] {5}")) == 5)
        #expect(try IMAPParser.literalLength(atEndOf: bytes("* OK done")) == nil)
    }

    @Test func parsesListWithSpecialUse() throws {
        let folder = try #require(IMAPParser.folder(from: IMAPParser.parse(bytes("* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\""))))
        #expect(folder.role == .sent)
        #expect(folder.path == "Sent")
        #expect(folder.name == "Sent")
        #expect(folder.selectable)

        let junk = try #require(IMAPParser.folder(from: IMAPParser.parse(bytes("* LIST () \".\" INBOX.Skr&AOQ-ppost"))))
        #expect(junk.role == .junk)
        #expect(junk.name == "Skräppost")
        #expect(junk.path == "INBOX.Skr&AOQ-ppost")

        let inbox = try #require(IMAPParser.folder(from: IMAPParser.parse(bytes("* LIST (\\Noselect) NIL inbox"))))
        #expect(inbox.role == .inbox)
        #expect(!inbox.selectable)

        let named = try #require(IMAPParser.folder(from: IMAPParser.parse(bytes("* LIST () \"/\" {11}\r\nDeleted Ite"))))
        #expect(named.name == "Deleted Ite")
        #expect(named.role == .other)
    }

    @Test func namesGiveARoleOnlyAtTheTopOrUnderInbox() throws {
        func role(_ line: String) throws -> FolderRole? {
            try IMAPParser.folder(from: IMAPParser.parse(bytes(line)))?.role
        }
        #expect(try role("* LIST () \"/\" Trash") == .trash)
        #expect(try role("* LIST () \"/\" INBOX/Trash") == .trash)
        #expect(try role("* LIST () \"/\" Projects/Trash") == .other)
        #expect(try role("* LIST () \"/\" INBOX/Old/Sent") == .other)
        #expect(try role("* LIST (\\Sent) \"/\" Projects/Outbox") == .sent)
    }

    @Test func parsesTaggedStatusWithCode() throws {
        let response = try IMAPParser.parse(bytes("A0001 NO [TRYCREATE] No such mailbox (really"))
        guard case let .status(tag, kind, code, text) = response else {
            Issue.record("not status")
            return
        }
        #expect(tag == "A0001")
        #expect(kind == .no)
        #expect(code == "TRYCREATE")
        #expect(text == "No such mailbox (really")
    }

    @Test(arguments: [
        ("* NAMESPACE ((\"INBOX.\" \".\")) NIL NIL", "INBOX.", "."),
        ("* NAMESPACE ((\"\" \"/\")) NIL NIL", "", "/"),
        ("* NAMESPACE ((\"INBOX\" \".\")) NIL NIL", "INBOX.", "."),
        ("* NAMESPACE ((\"\" NIL)) NIL NIL", "", nil)
    ])
    func readsThePersonalNamespace(line: String, prefix: String, delimiter: String?) throws {
        let response = try IMAPParser.parse(Data(line.utf8))
        #expect(IMAPParser.namespace(from: response) == IMAPNamespace(prefix: prefix, delimiter: delimiter))
    }

    /// No personal namespace, an odd shape, or a prefix no folder can be made under.
    @Test(arguments: [
        "* NAMESPACE NIL NIL NIL",
        "* NAMESPACE (()) NIL NIL",
        "* NAMESPACE (\"INBOX.\") NIL NIL",
        "* NAMESPACE ((\"a*b\" \"/\")) NIL NIL",
        "* NAMESPACE ((\"a%\" \"/\")) NIL NIL",
        "* NAMESPACE ((\"INBOX.\" \"..\")) NIL NIL",
        "* NAMESPACE ((\"" + String(repeating: "x", count: 300) + "\" \"/\")) NIL NIL",
        "* LIST () \"/\" INBOX"
    ])
    func refusesANamespaceThatIsNoPlaceForFolders(line: String) throws {
        let response = try IMAPParser.parse(Data(line.utf8))
        #expect(IMAPParser.namespace(from: response) == nil)
    }

    @Test func survivesArbitraryBytes() {
        var generator = SplitMix64(seed: 0x5EED_1A9)
        let alphabet = Array("* ()[]{}<>\"\\\r\n0123456789AFETCHLIST NIL".utf8)
        for _ in 0..<3000 {
            let length = Int.random(in: 0..<120, using: &generator)
            let noise = (0..<length).map { _ in
                Bool.random(using: &generator)
                    ? alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                    : UInt8.random(in: 0...255, using: &generator)
            }
            if let response = try? IMAPParser.parse(Data(noise)) {
                _ = IMAPParser.folder(from: response)
                _ = IMAPParser.namespace(from: response)
                if case let .data(_, _, values) = response { _ = FetchItems(values).summary() }
            }
            _ = try? IMAPParser.literalLength(atEndOf: Data(noise))
            _ = IMAPParser.allowsLiterals(firstLine: Data(noise))
        }
    }

    @Test func literalsOnlyWhereTheGrammarAllowsThem() {
        #expect(IMAPParser.allowsLiterals(firstLine: bytes("* 1 FETCH (BODY[] {5}")))
        #expect(IMAPParser.allowsLiterals(firstLine: bytes("* LIST () \"/\" {3}")))
        #expect(!IMAPParser.allowsLiterals(firstLine: bytes("* OK [ALERT] see {5}")))
        #expect(!IMAPParser.allowsLiterals(firstLine: bytes("* BYE going {5}")))
        #expect(!IMAPParser.allowsLiterals(firstLine: bytes("A0001 NO [TRYCREATE] {3}")))
        #expect(!IMAPParser.allowsLiterals(firstLine: bytes("+ go ahead {9}")))
    }

    @Test func unreadableInternalDateFallsBackToNow() throws {
        let response = try IMAPParser.parse(bytes("* 1 FETCH (UID 7 INTERNALDATE \"yesterday-ish\")"))
        guard case let .data(_, _, values) = response else {
            Issue.record("not data")
            return
        }
        let summary = try #require(FetchItems(values).summary())
        #expect(abs(summary.internalDate.timeIntervalSinceNow) < 60)
    }

    @Test func searchDatesHaveFourDigitYears() throws {
        #expect(InternalDate.searchDate(.distantPast) == "1-Jan-0001")
        #expect(InternalDate.searchDate(Date(timeIntervalSince1970: 1_793_959_200)) == "6-Nov-2026")
    }
}

/// A seeded generator, so a failing input can be reproduced.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
