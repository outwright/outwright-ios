// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightUI

/// Counts how often stored mail is opened; handles nothing itself.
private final class CountingOpener: MessageOpening {
    let calls = Mutex(0)
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        calls.withLock { $0 += 1 }
        return nil
    }
    var count: Int { calls.withLock { $0 } }
}

/// Notes whether any opening ran on the main thread, and answers with the facts given.
private final class ThreadNotingOpener: MessageOpening {
    let onMain = Mutex(false)
    let facts: ProtectionFacts?
    init(facts: ProtectionFacts? = nil) { self.facts = facts }
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        if Thread.isMainThread { onMain.withLock { $0 = true } }
        guard let facts, let message = try? MIMEParser.parse(raw, limits: limits) else { return nil }
        return OpenedMessage(message: message, facts: facts)
    }
}

@MainActor @Suite struct OpeningTests {
    @Test func replyForwardAndDraftOpenAwayFromTheMainThread() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let body = try message(subject: "Hej", text: "text")
        let id = try box.add(anna, uid: 1, body: body)
        let draft = try box.add(anna, .drafts, uid: 2, body: body)
        let opener = ThreadNotingOpener()
        box.store.setOpenings([opener])
        for kind in [ComposeRequest.Kind.reply(id), .replyAll(id), .forward(id), .draft(draft)] {
            let model = await ComposeModel.make(request: ComposeRequest(kind: kind), store: box.store, accounts: [anna])
            #expect(shownText(model).contains("text"))
        }
        #expect(opener.onMain.withLock { $0 } == false)
    }

    /// A decrypted mail whose From is only the outer one may claim to be the owner's own: its reply
    /// does not then go to its To (perhaps the forger), as a reply to one's own mail would.
    @Test func replyToDecryptedMailClaimingTheOwnersFromGoesToNoOneElse() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let body = Data(
            "From: anna@example.org\r\nTo: mallory@example.org\r\nSubject: Hi\r\nMessage-ID: <x@example.org>\r\n\r\nHi\r\n"
                .utf8)
        let id = try box.add(anna, uid: 1, from: anna.email, body: body)
        box.store.setOpenings([ThreadNotingOpener(
            facts: ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil))])
        let forged = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(!forged.to.map(\.email).contains("mallory@example.org"))

        box.store.setOpenings([ThreadNotingOpener(
            facts: ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil, fromIsProtected: true))])
        let own = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(own.to.map(\.email) == ["mallory@example.org"])
    }

    @Test func anUnreadableMessageSaysSo() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let body = try message(subject: "Hej", text: "text")
        box.store.setOpenings([ThreadNotingOpener(
            facts: ProtectionFacts(decryption: .unreadable, signature: .none, resentBy: nil))])
        #expect(await MessageContent.read(body, store: box.store)?.isUnreadable == true)
        box.store.setOpenings([ThreadNotingOpener(
            facts: ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil))])
        #expect(await MessageContent.read(body, store: box.store)?.isUnreadable == false)
    }

    @Test func everySiteUsesTheOpener() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let body = try message(subject: "Hej", text: "text")
        let id = try box.add(anna, uid: 1, body: body)
        let row = try #require(try box.store.message(id))
        let opener = CountingOpener()
        box.store.setOpenings([opener])

        _ = await MessageContent.read(body, store: box.store)
        #expect(opener.count == 1)

        _ = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(opener.count == 2)

        _ = SearchModel.attachmentFiles(box.store, [row])
        #expect(opener.count == 3)
    }

    @Test func forwardAndOpenDraftGoThroughTheOpener() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let body = try message(subject: "Hej", text: "text")
        let id = try box.add(anna, uid: 1, body: body)
        let draft = try box.add(anna, .drafts, uid: 2, body: body)
        let opener = CountingOpener()
        box.store.setOpenings([opener])

        _ = await ComposeModel.make(request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna])
        #expect(opener.count == 1)

        _ = await ComposeModel.make(request: ComposeRequest(kind: .draft(draft)), store: box.store, accounts: [anna])
        #expect(opener.count == 2)
    }

    @Test func replyToAnUnopenedProtectedRowQuotesNothingFromThePreview() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, subject: "...", body: Data(
                ("From: bo@example.org\r\nSubject: ...\r\n"
                    + "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"b\"\r\n\r\n"
                    + "--b\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n--b--\r\n").utf8))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(try #require(try box.store.message(id)).isProtected)
        #expect(!shownText(model).contains("Encrypted"))
        #expect(!shownText(model).contains("preview"))
    }

    @Test func theEncryptedMarkerIsOnlyForARowNotOpened() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1)
        var row = try #require(try box.store.message(id))
        row.isProtected = true
        row.preview = ""
        #expect(row.shownPreview() == L10n.string("Encrypted message"))
        row.isDecrypted = true
        #expect(row.shownPreview().isEmpty)
    }
}
