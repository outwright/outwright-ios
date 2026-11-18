// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import Synchronization
import Testing

@testable import OutwrightStore

/// Opens any `multipart/encrypted` message as a fixed inner one, counting its calls.
final class FakeOpener: MessageOpening {
    let inner: MIMEMessage
    let facts: ProtectionFacts?
    let calls = Mutex(0)
    /// The account each call was told.
    let accounts = Mutex<[String?]>([])

    /// `handlesAny`: opens every message, not only `multipart/encrypted` (a message the hook marks).
    let handlesAny: Bool

    init(
        subject: String = "Budget", text: String = "Quarterly numbers", facts: ProtectionFacts? = nil,
        attachments: [OutwrightMIME.Attachment] = [], handlesAny: Bool = false
    ) {
        self.handlesAny = handlesAny
        var message = MIMEMessage()
        message.attachments = attachments
        message.subject = subject
        message.textBody = text
        message.from = [Address(name: nil, email: "bo@example.org")]
        inner = message
        self.facts =
            facts ?? ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil)
    }

    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        calls.withLock { $0 += 1 }
        accounts.withLock { $0.append(account) }
        guard handlesAny || MessageReader.isEncryptedShape(raw) else { return nil }
        return OpenedMessage(message: inner, facts: facts)
    }
}

/// A message whose top level is `multipart/encrypted` (RFC 1847), its outer subject "...".
func encryptedMime(subject: String = "...") -> Data {
    let text = """
        From: bo@example.org\r
        Subject: \(subject)\r
        Content-Type: multipart/encrypted; protocol="application/pgp-encrypted"; boundary="b"\r
        \r
        --b\r
        Content-Type: application/pgp-encrypted\r
        \r
        Version: 1\r
        --b\r
        Content-Type: application/octet-stream; name="encrypted.asc"\r
        Content-Disposition: attachment; filename="encrypted.asc"\r
        \r
        -----BEGIN-----\r
        --b--\r

        """
    return Data(text.utf8)
}

@Suite struct ProtectedRowTests {
    @Test func encryptedShapeShowsEncryptedMessage() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        let stored = try #require(try f.store.message(id))
        #expect(stored.isProtected)
        #expect(stored.preview.isEmpty)
        #expect(try f.store.search("Encrypted", limit: 10).isEmpty)
        #expect(stored.subject == "...")
        #expect(!stored.hasAttachment)
    }

    @Test func openingIsToldTheStoredMessagesAccount() throws {
        let f = try Fixture()
        let opener = FakeOpener()
        f.store.setOpenings([opener])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        _ = try f.store.opened(id)
        let account = f.account.id.raw.uuidString
        #expect(opener.accounts.withLock { $0 } == [account, account])
    }

    @Test func openerRewritesSubjectAndPreview() throws {
        let f = try Fixture()
        f.store.setOpenings([FakeOpener()])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        let stored = try #require(try f.store.message(id))
        #expect(stored.isProtected)
        #expect(stored.subject == "Budget")
        #expect(stored.preview == "Quarterly numbers")
        #expect(try f.store.search("Budget", limit: 10).map(\.id) == [id])
    }

    @Test func upsertKeepsProtectedSubject() throws {
        let f = try Fixture()
        f.store.setOpenings([FakeOpener()])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...", read: true)])
        let stored = try #require(try f.store.message(id))
        #expect(stored.subject == "Budget")
        #expect(stored.preview == "Quarterly numbers")
        #expect(stored.isRead)
        #expect(stored.isProtected)
    }

    @Test func innerAttachmentsDecidePaperclip() throws {
        let f = try Fixture()
        f.store.setOpenings([FakeOpener()])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        #expect(try #require(try f.store.message(id)).hasAttachment == false)
    }

    @Test func aPlainMessageIsNotProtected() throws {
        let f = try Fixture()
        f.store.setOpenings([FakeOpener()])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        try f.store.setBody(mime("hej"), for: id)
        let stored = try #require(try f.store.message(id))
        #expect(!stored.isProtected)
        #expect(stored.preview == "preview 1")
        #expect(try f.store.opened(id)?.message.textBody?.contains("hej") == true)
    }

    @Test func upsertKeepsThePaperclipOfAnOpenedRow() throws {
        let f = try Fixture()
        let file = OutwrightMIME.Attachment(filename: "a.txt", mimeType: "text/plain", contentID: nil, isInline: false, data: Data("x".utf8))
        f.store.setOpenings([FakeOpener(attachments: [file])])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        #expect(try #require(try f.store.message(id)).hasAttachment)
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")])
        #expect(try #require(try f.store.message(id)).hasAttachment)
    }

    @Test func aRowMarkedByTheHookKeepsItsThreadOnUpsert() throws {
        let f = try Fixture()
        f.store.setOpenings([FakeOpener(handlesAny: true)])
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, thread: "own")]).first)
        try f.store.setBody(mime("hej"), for: id)
        #expect(try #require(try f.store.message(id)).isProtected)
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, thread: "subject:hej")])
        #expect(try #require(try f.store.message(id)).threadID == ThreadID(raw: "own"))
    }

    @Test func openedRowIsDecryptedAndAnUnopenedOneIsNot() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1, subject: "...")]).first)
        try f.store.setBody(encryptedMime(), for: id)
        #expect(try #require(try f.store.message(id)).isDecrypted == false)
        f.store.setOpenings([FakeOpener(text: "")])
        try f.store.setBody(encryptedMime(), for: id)
        let stored = try #require(try f.store.message(id))
        #expect(stored.isDecrypted)
        #expect(stored.preview.isEmpty)
    }
}
