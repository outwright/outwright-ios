// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor @Suite struct ComposeKeepingTests {
    private func drafts(_ box: Mailbox, _ account: Account) throws -> [MessageRow] {
        let folder = try box.folder(account, .drafts)
        return try box.store.messages(InboxQuery(scope: .folder(folder.id), inboxClass: nil, filter: .all), limit: 50)
    }

    @Test func pastedRecipientsAreAllSent() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Två"
        try model.send(typed: [.to: "a@x.example, b@y.example", .cc: "Cy <c@z.example>;"])
        let draft = try #require(try drafts(box, anna).first)
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.to.map(\.email) == ["a@x.example", "b@y.example"])
        #expect(parsed.cc.map(\.email) == ["c@z.example"])
    }

    @Test func typedTextThatIsNoAddressRefusesTheSendAndNamesIt() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.to = [Address(name: nil, email: "bo@example.org")]
        #expect(throws: ComposeError.notAnAddress("bo at work")) {
            try model.send(typed: [.to: "a@x.example, bo at work"])
        }
        #expect(!model.isFinished)
        #expect(model.to.map(\.email) == ["bo@example.org"])
        #expect(try box.store.pendingActions().isEmpty)
    }

    @Test func goingToTheBackgroundKeepsTheDraftAndTheComposeStaysOpen() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Halvfärdigt"
        try model.keep()
        #expect(!model.isFinished)
        let draft = try #require(try drafts(box, anna).first)
        #expect(draft.subject == "Halvfärdigt")
        #expect(try box.store.pendingActions().map(\.action) == [.saveDraft(draft.id)])

        model.subject = "Färdigt"
        try model.close()
        #expect(try drafts(box, anna).map(\.id) == [draft.id])
        #expect(try drafts(box, anna).first?.subject == "Färdigt")
        #expect(try box.store.pendingActions().count == 2)
    }

    @Test func savingAgainKeepsTheUIDTheServerGaveMeanwhile() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Första"
        try model.keep()
        let draft = try #require(try drafts(box, anna).first)
        // The queued save reached the server, which numbered the draft.
        try box.store.setUID(55, for: draft.id)
        model.subject = "Andra"
        try model.keep()
        #expect(try box.store.message(draft.id)?.uid == 55)
    }

    // MARK: - Closing with ✕

    @Test func xWithChangesAsks() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        #expect(model.closeChoice == .close)
        model.subject = "Halvfärdigt"
        #expect(model.closeChoice == .ask)
    }

    @Test func deleteDraftRemovesTheSavedDraft() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        first.subject = "Utkast"
        try first.close()
        let draft = try #require(try drafts(box, anna).first)

        let reopened = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(draft.id)), store: box.store, accounts: [anna])
        reopened.body = AttributedString("Ändrat")
        try await reopened.discardDraft()
        #expect(reopened.isFinished)
        #expect(try drafts(box, anna).isEmpty)
        #expect(try box.store.pendingActions().map(\.action).contains(.delete(draft.id)))

        // A message never saved just closes: nothing is written or queued.
        let fresh = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        fresh.subject = "Aldrig sparat"
        let queued = try box.store.pendingActions().count
        try await fresh.discardDraft()
        #expect(fresh.isFinished)
        #expect(try drafts(box, anna).isEmpty)
        #expect(try box.store.pendingActions().count == queued)
    }

    // MARK: - Starting from a message whose body is not on the phone

    private static let longText = (1...60).map { "Mening nummer \($0)." }.joined(separator: " ")

    @Test func draftWithoutStoredBodyIsFetchedNotTruncated() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, .drafts, uid: 7, subject: "Utkast")
        let full = try message(subject: "Utkast", text: Self.longText)
        let store = box.store
        let model = try #require(
            await ComposeModel.start(
                request: ComposeRequest(kind: .draft(id)), store: store, accounts: [anna]
            ) { _ = try? store.setBody(full, for: $0) })
        #expect(String(model.body.characters).contains("Mening nummer 60."))
    }

    @Test func unfetchableDraftDoesNotOpen() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, .drafts, uid: 7, subject: "Utkast")
        var asked: [MessageID] = []
        let model = await ComposeModel.start(
            request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna]
        ) { asked.append($0) }
        #expect(model == nil)
        #expect(asked == [id])
    }

    @Test func replyQuotesTheFullBody() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 3, subject: "Lång")
        let full = try message(subject: "Lång", text: Self.longText)
        let store = box.store
        let model = try #require(
            await ComposeModel.start(
                request: ComposeRequest(kind: .reply(id)), store: store, accounts: [anna]
            ) { _ = try? store.setBody(full, for: $0) })
        #expect(shownText(model).contains("Mening nummer 60."))
    }

    /// A reply whose original can't be had opens all the same, without a quote, and says so. It still
    /// answers the original: In-Reply-To and References name it.
    @Test func unfetchableReplyOpensWithoutQuote() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 3, subject: "Lång")
        var row = try #require(try box.store.message(id))
        row.messageIDHeader = "orig@example.org"
        _ = try box.store.upsert([row])
        for kind in [ComposeRequest.Kind.reply(id), .replyAll(id)] {
            let model = try #require(
                await ComposeModel.start(
                    request: ComposeRequest(kind: kind), store: box.store, accounts: [anna], fetchBody: { _ in }))
            #expect(model.originalNotQuoted)
            #expect(!shownText(model).contains("preview 3"))
            #expect(model.subject.hasSuffix("Lång"))
            #expect(model.to.map(\.email) == ["bo@example.org"])
            try model.send()
            let draft = try #require(model.draftID)
            let sent = try MIMEParser.parse(try #require(try box.store.body(draft)))
            #expect(sent.inReplyTo == ["orig@example.org"])
            #expect(sent.references == ["orig@example.org"])
        }
    }

    @Test func unfetchableForwardDoesNotOpen() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 3, subject: "Lång")
        let model = await ComposeModel.start(
            request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna], fetchBody: { _ in })
        #expect(model == nil)
    }

    /// A refused delete leaves the message open, its draft kept, and says why.
    @Test func refusedDraftDeleteKeepsTheSheetOpen() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Utkast"
        try model.keep()
        let draft = try #require(model.draftID)
        model.subject = "Utkast, ändrat"
        try box.store.refuseQueuedActions(true)
        await #expect(throws: ComposeError.store) { try await model.discardDraft() }
        try box.store.refuseQueuedActions(false)
        #expect(!model.isFinished)
        #expect(model.closeChoice == .ask)
        #expect(model.draftID == draft)
        #expect(try drafts(box, anna).map(\.id) == [draft])
    }
}
