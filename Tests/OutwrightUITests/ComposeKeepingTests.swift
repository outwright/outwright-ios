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
}
