// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightNet
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A draft as the composer keeps it: the whole message, Bcc included.
func draftData(messageID: String = "draft1@example.org") throws -> Data {
    let message = OutgoingMessage(
        from: Address(name: "Jörgen", email: "jk@example.org"),
        to: [Address(name: "Bo", email: "bo@example.org")], cc: [Address(name: nil, email: "cy@example.org")],
        bcc: [Address(name: nil, email: "dee@example.org")], subject: "Plans", textBody: "See you at noon",
        htmlBody: nil, attachments: [], inReplyTo: nil, references: [], date: fixedNow,
        messageID: messageID)
    return try MIMEWriter.write(message, includeBcc: true)
}

/// Syncs folders and the Inbox; returns the syncer.
func synced(_ h: Harness) async throws -> AccountSyncer {
    let syncer = h.syncer()
    try await syncer.syncFolders()
    try await syncer.sync(try h.folder(.inbox).id)
    return syncer
}

/// A local draft row in Drafts, numbered `uid` (0: never saved to the server), holding `data`.
func localDraft(_ h: Harness, uid: UInt32, data: Data, header: String? = "draft1@example.org") throws -> MessageID {
    let drafts = try h.folder(.drafts)
    let row = MessageRow(
        id: MessageID(raw: 0), accountID: h.account.id, folderID: drafts.id, uid: uid,
        threadID: ThreadID(raw: "draft1@example.org"), from: Address(name: nil, email: "jk@example.org"),
        to: [Address(name: nil, email: "bo@example.org")], cc: [], subject: "Plans", preview: "", date: fixedNow,
        isRead: true, isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: .focused,
        hasBody: false, threadCount: 1, messageIDHeader: header)
    let id = try #require(try h.store.upsert([row]).first)
    try h.store.setBody(data, for: id)
    return id
}

@Suite struct ActionTests {
    @Test func deleteMovesToTrashOnServer() async throws {
        let server = await standardServer()
        await server.deliver(mail("bin me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            try await syncer.runActions()

            #expect(await server.messages(in: "INBOX").isEmpty)
            let trash = await server.messages(in: "Trash")
            #expect(trash.count == 1)
            #expect(try h.store.pendingActions().isEmpty)
            // Settled with the uid the server gave it.
            #expect(try h.rows(.trash).map(\.uid) == trash.map(\.uid))
            #expect(try h.rows(.trash).first?.id == id)
        }
    }

    @Test func archiveCreatesFolderWhenMissing() async throws {
        let server = await standardServer()
        await server.deliver(mail("keep for later"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            // The account has no archive yet, but archiving works at once.
            let archive = try h.folder(.archive)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.move(id, to: .archive))
            try await syncer.runActions()

            #expect(await server.messages(in: "INBOX").isEmpty)
            #expect(await server.messages(in: archive.path).count == 1)
            #expect(try h.store.pendingActions().isEmpty)

            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.archive).id)
            #expect(try h.rows(.archive).map(\.id) == [id])
        }
    }

    /// #4: a server that keeps every folder under the Inbox gets the missing Archive there too.
    @Test func aMissingFolderIsMadeUnderTheInboxWhereTheServerKeepsThem() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        await server.addFolder("INBOX.Sent", specialUse: "\\Sent")
        await server.addFolder("INBOX.Drafts", specialUse: "\\Drafts")
        await server.addFolder("INBOX.Trash", specialUse: "\\Trash")
        await server.deliver(mail("keep for later"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.move(id, to: .archive))
            try await syncer.runActions()

            #expect(await server.messages(in: "INBOX").isEmpty)
            #expect(await server.messages(in: "INBOX.Archive").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// #4: a server that lists only the Inbox says through NAMESPACE where folders go.
    @Test func aServerWithOnlyAnInboxGetsItsFolderWhereItsNamespaceSays() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox()
        await server.deliver(mail("keep for later"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.move(id, to: .archive))
            try await syncer.runActions()

            #expect(await server.messages(in: "INBOX.Archive").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// #4: a folder made at the wrong place, with a change waiting on it, moves to where the server
    /// keeps its folders once that can be told, and the change goes through.
    @Test func aFolderMadeAtTheWrongPlaceMovesWithWhatWaitsOnIt() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox(announcingNamespace: false)
        await server.deliver(mail("keep for later"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.move(id, to: .archive))
            await #expect(throws: SyncError.self) { try await syncer.runActions() }

            await server.addFolder("INBOX.Sent", specialUse: "\\Sent")
            try await syncer.syncFolders()
            try await syncer.runActions()

            #expect(await server.messages(in: "INBOX.Archive").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
            #expect(try h.store.folders(h.account.id).filter { $0.kind == .archive }.map(\.path) == ["INBOX.Archive"])
        }
    }

    /// #1: a drop between storing the new copy of a draft and removing the old one leaves one
    /// copy once the save is run again.
    @Test func aDropWhileSavingADraftStillLeavesOneCopy() async throws {
        let server = await standardServer()
        let data = try draftData()
        let saved = await server.deliver(data, to: "Drafts", flags: ["\\Draft", "\\Seen"])
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: saved, data: data)
            try h.store.apply(.saveDraft(id))
            await server.dropAtAppend(to: "Drafts", afterStoring: true)
            try? await syncer.runActions()
            await syncer.disconnect()
            try await syncer.runActions()

            let drafts = await server.messages(in: "Drafts")
            #expect(drafts.count == 1)
            #expect(try h.store.message(id)?.uid == drafts.first?.uid)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func flagAndReadReachServer() async throws {
        let server = await standardServer()
        await server.deliver(mail("mark me"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setRead(id, true))
            try h.store.apply(.setFlagged(id, true))
            try await syncer.runActions()
            #expect(await server.messages(in: "INBOX").first?.flags == ["\\Seen", "\\Flagged"])

            try h.store.apply(.setRead(id, false))
            try await syncer.runActions()
            #expect(await server.messages(in: "INBOX").first?.flags == ["\\Flagged"])
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func sendSubmitsAppendsToSentAndRemovesDraft() async throws {
        let server = await standardServer()
        let data = try draftData()
        let serverDraft = await server.deliver(data, to: "Drafts", flags: ["\\Draft", "\\Seen"])
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: serverDraft, data: data)
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()

            let received = await h.smtp.received
            #expect(received.count == 1)
            #expect(received.first?.from == "jk@example.org")
            #expect(Set(received.first?.to ?? []) == ["bo@example.org", "cy@example.org", "dee@example.org"])
            let wire = String(decoding: received.first?.data ?? Data(), as: UTF8.self)
            #expect(!wire.contains("dee@example.org"))
            #expect(wire.contains("draft1@example.org"))

            let sent = await server.messages(in: "Sent")
            #expect(sent.count == 1)
            #expect(sent.first?.flags.contains("\\Seen") == true)
            // The owner's own copy remembers the Bcc; the recipients' never shows it.
            let sentText = String(decoding: sent.first?.data ?? Data(), as: UTF8.self)
            #expect(sentText.contains("dee@example.org"))
            #expect(await server.messages(in: "Drafts").isEmpty)
            // The draft is no draft any more: its row is the copy in Sent.
            #expect(try h.rows(.drafts).isEmpty)
            #expect(try h.store.message(id)?.folderID == (try h.folder(.sent)).id)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func sendOfAnUnsavedDraftRemovesItHere() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()
            #expect(await h.smtp.received.count == 1)
            #expect(try h.store.message(id)?.folderID == (try h.folder(.sent)).id)
            #expect(await h.imap.messages(in: "Sent").count == 1)
        }
    }

    @Test func aDraftWithACalendarIsSentWithIt() async throws {
        let ics = Data("BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n".utf8)
        let message = OutgoingMessage(
            from: Address(name: nil, email: "jk@example.org"), to: [Address(name: nil, email: "org@example.org")],
            cc: [], bcc: [], subject: "Accepted: Planning", textBody: "Accepted", htmlBody: nil, attachments: [],
            inReplyTo: nil, references: [], date: fixedNow, messageID: "draft1@example.org",
            calendar: CalendarPart(method: "REPLY", data: ics))
        try await withHarness { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try MIMEWriter.write(message, includeBcc: true))
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()
            let data = try #require(await h.smtp.received.first?.data)
            let wire = try MIMEParser.parse(data)
            #expect(wire.calendar == CalendarPart(method: "REPLY", data: ics))
            #expect(wire.textBody == "Accepted")
            // Sent as the text's alternative, once, not as an attached file.
            let top = try #require(wire.rawHeaders.first { $0.name.lowercased() == "content-type" }?.value)
            #expect(top.lowercased().hasPrefix("multipart/alternative"))
            #expect(wire.attachments.count == 1)
        }
    }

    @Test func temporarySMTPFailureKeepsTheDraftAndTheAction() async throws {
        let smtp = FakeSMTPServer(rejectRecipient: "cy@example.org", rejectCode: 450)
        try await withHarness(smtp: smtp) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            await #expect(throws: SyncError.self) {
                try await syncer.runActions()
            }
            #expect(try h.store.message(id) != nil)
            #expect(try h.store.pendingActions().count == 1)
            #expect(await h.imap.messages(in: "Sent").isEmpty)
        }
    }

    @Test func saveDraftKeepsOneCopyOnTheServer() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.saveDraft(id))
            try await syncer.runActions()
            var drafts = await h.imap.messages(in: "Drafts")
            #expect(drafts.count == 1)
            #expect(drafts.first?.flags.contains("\\Draft") == true)
            #expect(try h.store.message(id)?.uid == drafts.first?.uid)

            try h.store.apply(.saveDraft(id))
            try await syncer.runActions()
            drafts = await h.imap.messages(in: "Drafts")
            #expect(drafts.count == 1)
            #expect(try h.store.message(id)?.uid == drafts.first?.uid)
        }
    }

    @Test(arguments: 1...6) func actionReplayedOnceAfterDrop(afterCommands: Int) async throws {
        let server = await standardServer()
        await server.deliver(mail("drop me"), to: "INBOX")
        try await withHarness(server) { h in
            let first = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            await first.disconnect()

            await server.dropNextConnection(afterCommands: afterCommands)
            let syncer = h.syncer()
            try? await syncer.runActions()
            try await syncer.runActions()

            #expect(await server.messages(in: "Trash").count == 1)
            #expect(await server.messages(in: "INBOX").isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
            try await syncer.sync(try h.folder(.trash).id)
            #expect(try h.rows(.trash).count == 1)
        }
    }

    @Test(arguments: 1...9) func actionReplayedOnceAfterDropWithoutMove(afterCommands: Int) async throws {
        let server = await standardServer(offersMove: false)
        await server.deliver(mail("drop me by copy", id: "copy@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let first = try await synced(h)
            try await first.sync(try h.folder(.trash).id)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            await first.disconnect()

            await server.dropNextConnection(afterCommands: afterCommands)
            let syncer = h.syncer()
            try? await syncer.runActions()
            try await syncer.runActions()

            #expect(await server.messages(in: "Trash").count == 1)
            #expect(await server.messages(in: "INBOX").isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func queuedActionsFollowARenumberedFolder() async throws {
        let server = await standardServer()
        let first = await server.deliver(mail("deleted elsewhere", id: "a@example.org"), to: "INBOX")
        await server.deliver(mail("bin me", id: "b@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first { $0.subject == "bin me" }?.id)
            try h.store.apply(.delete(id))
            #expect(try h.store.pendingActions().first?.sourceUID == 2)

            // The server rebuilds the folder: "bin me" is now uid 1 and another message has uid 2.
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Deleted"], on: [first], add: true)
            try await side.expunge([first])
            await side.logout()
            await server.deliver(mail("bystander", id: "c@example.org"), to: "INBOX")
            await server.renumber("INBOX", uidValidity: 9_999)

            try await syncer.runActions()
            let inbox = await server.messages(in: "INBOX")
            #expect(inbox.count == 1)
            let inboxText = String(decoding: inbox.first?.data ?? Data(), as: UTF8.self)
            #expect(inboxText.contains("bystander"))
            #expect(await server.messages(in: "Trash").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func actionForAMessageGoneFromARenumberedFolderWaits() async throws {
        let server = await standardServer()
        let only = await server.deliver(mail("deleted elsewhere", id: "a@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.setFlagged(id, true))
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            try await side.setFlags(["\\Deleted"], on: [only], add: true)
            try await side.expunge([only])
            await side.logout()
            await server.deliver(mail("bystander", id: "c@example.org"), to: "INBOX")
            await server.renumber("INBOX", uidValidity: 9_999)

            try await syncer.runActions()
            #expect(await server.messages(in: "INBOX").first?.flags.isEmpty == true)
            // Left queued, no longer tied to the old number.
            #expect(try h.store.pendingActions().map(\.sourceUID) == [0])
        }
    }

    @Test func deleteMakesTrashWhenTheAccountHasNone() async throws {
        let server = FakeIMAPServer()
        await server.deliver(mail("bin me"), to: "INBOX")
        await server.deliver(mail("spam"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let rows = try h.rows(.inbox)
            try h.store.apply(.delete(try #require(rows.first?.id)))
            try h.store.apply(.move(try #require(rows.last?.id), to: .junk))
            try await syncer.runActions()
            #expect(await server.messages(in: try h.folder(.trash).path).count == 1)
            #expect(await server.messages(in: try h.folder(.junk).path).count == 1)
            #expect(await server.messages(in: "INBOX").isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func draftWithoutMessageIDKeepsTheOneMintedForItsFirstTry() async throws {
        let rejecting = FakeSMTPServer(rejectRecipient: "cy@example.org", rejectCode: 450)
        try await withHarness(smtp: rejecting) { h in
            _ = try await synced(h)
            var raw = String(decoding: try draftData(), as: UTF8.self)
            raw = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("Message-ID:") }.joined(separator: "\r\n")
            let id = try localDraft(h, uid: 0, data: Data(raw.utf8), header: nil)
            try h.store.apply(.send(draftID: id))
            try? await h.syncer().runActions()
            let minted = try #require(try h.store.message(id)?.messageIDHeader)
            // The draft itself carries the id, so its copy on the server can be found by it.
            let kept = try MIMEParser.parseHeaders(try #require(try h.store.body(id)))
            #expect(kept.messageID == minted)
            #expect(kept.bcc.map(\.email) == ["dee@example.org"])

            let accepting = FakeSMTPServer()
            let port = try await accepting.start()
            var account = h.account
            account.smtp = MailEndpoint(host: "127.0.0.1", port: port, security: "plainLoopbackOnly")
            try h.store.save(account)
            let retry = AccountSyncer(account: account, store: h.store, secrets: h.secrets, now: { fixedNow })
            try await retry.runActions()
            let received = await accepting.received
            await accepting.stop()
            #expect(received.count == 1)
            let receivedText = String(decoding: received.first?.data ?? Data(), as: UTF8.self)
            #expect(receivedText.contains(minted))
        }
    }

    @Test func blockedActionDoesNotTouchABystanderAfterRenumbering() async throws {
        let server = await standardServer()
        await server.deliver(mail("other draft", id: "x@example.org"), to: "Drafts")
        await server.deliver(try draftData(), to: "Drafts", flags: ["\\Draft"])
        let smtp = FakeSMTPServer(rejectRecipient: "cy@example.org", rejectCode: 450)
        try await withHarness(server, smtp: smtp) { h in
            let syncer = try await synced(h)
            try await syncer.sync(try h.folder(.drafts).id)
            let draft = try #require(try h.rows(.drafts).first { $0.subject == "Plans" })
            #expect(draft.uid == 2)
            try h.store.setBody(try draftData(), for: draft.id)
            // The send is refused, so the delete behind it never gets its turn.
            try h.store.apply(.send(draftID: draft.id))
            try h.store.apply(.delete(draft.id))
            await #expect(throws: SyncError.self) { try await syncer.runActions() }

            // The server rebuilds Drafts: the draft is uid 1 now and a bystander has its old uid 2.
            let side = try await h.sideClient()
            _ = try await side.select("Drafts")
            try await side.setFlags(["\\Deleted"], on: [1], add: true)
            try await side.expunge([1])
            await side.logout()
            await server.deliver(mail("bystander", id: "b@example.org"), to: "Drafts")
            await server.renumber("Drafts", uidValidity: 777)

            await #expect(throws: SyncError.self) { try await syncer.sync(try h.folder(.drafts).id) }
            // Now the send goes through, and the delete gets its turn.
            let accepting = FakeSMTPServer()
            let port = try await accepting.start()
            var account = h.account
            account.smtp = MailEndpoint(host: "127.0.0.1", port: port, security: "plainLoopbackOnly")
            try h.store.save(account)
            let retry = AccountSyncer(account: account, store: h.store, secrets: h.secrets, now: { fixedNow })
            try? await retry.runActions()
            #expect(await accepting.received.count == 1)
            await accepting.stop()
            let drafts = await server.messages(in: "Drafts")
            let texts = drafts.map { String(decoding: $0.data, as: UTF8.self) }
            #expect(texts.contains { $0.contains("bystander") })
            let trash = await server.messages(in: "Trash")
            #expect(!trash.contains { String(decoding: $0.data, as: UTF8.self).contains("bystander") })
        }
    }

    @Test func cleanUpWithoutUIDPlusNeverExpungesOthers() async throws {
        let server = await standardServer(offersMove: false, offersUIDPlus: false)
        let mine = await server.deliver(mail("mine", id: "m@example.org"), to: "INBOX")
        await server.deliver(mail("marked by another client", id: "o@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            try await syncer.sync(try h.folder(.trash).id)
            let id = try #require(try h.rows(.inbox).first { $0.subject == "mine" }?.id)
            try h.store.apply(.delete(id))
            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            // Our copy reached Trash and the original was marked before a drop; another
            // client marked a message of its own meanwhile.
            _ = try await side.move([mine], to: "Trash")
            try await side.setFlags(["\\Deleted"], on: [2], add: true)
            await side.logout()

            try await syncer.runActions()
            #expect(await server.messages(in: "INBOX").count == 2)
            #expect(await server.messages(in: "Trash").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func runnerThatMayNoLongerSendLeavesTheSendQueued() async throws {
        try await withHarness { h in
            _ = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            let client = try await h.sideClient()
            var runner = ActionRunner(
                account: h.account, store: h.store, client: client, secrets: h.secrets, now: fixedNow,
                folders: try h.store.folders(h.account.id), mayContinue: { false })
            _ = try await runner.run(try h.store.pendingActions())
            await client.logout()
            #expect(await h.smtp.received.isEmpty)
            #expect(try h.store.pendingActions().count == 1)
            #expect(try h.store.message(id) != nil)
        }
    }

    @Test func moveAlreadyGoneFromSourceCountsAsDone() async throws {
        let server = await standardServer()
        let uid = await server.deliver(mail("moved elsewhere"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))

            let side = try await h.sideClient()
            _ = try await side.select("INBOX")
            _ = try await side.move([uid], to: "Trash")
            await side.logout()

            try await syncer.runActions()
            #expect(await server.messages(in: "Trash").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
            try await syncer.sync(try h.folder(.trash).id)
            #expect(try h.rows(.trash).count == 1)
        }
    }

    @Test(arguments: [true, false]) func actionsOnAnUnsettledMoveFollowTheMessage(uidPlus: Bool) async throws {
        let server = await standardServer(offersUIDPlus: uidPlus)
        await server.deliver(mail("move then flag", id: "follow@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            try h.store.apply(.setFlagged(id, true))
            #expect(try h.store.pendingActions().last?.sourceUID == 0)
            try await syncer.runActions()

            let trash = await server.messages(in: "Trash")
            #expect(trash.count == 1)
            #expect(trash.first?.flags.contains("\\Flagged") == true)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test(arguments: [true, false]) func permanentDeleteFromTrash(uidPlus: Bool) async throws {
        let server = await standardServer(offersUIDPlus: uidPlus)
        await server.deliver(mail("gone for good"), to: "Trash")
        await server.deliver(mail("stays"), to: "Trash")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            try await syncer.sync(try h.folder(.trash).id)
            let id = try #require(try h.rows(.trash).first { $0.subject == "gone for good" }?.id)
            try h.store.apply(.delete(id))
            try await syncer.runActions()

            let trash = await server.messages(in: "Trash")
            if uidPlus {
                #expect(trash.count == 1)
            } else {
                // Without UIDPLUS a plain EXPUNGE could take other messages; it is left marked.
                #expect(trash.count == 2)
                #expect(trash.first?.flags.contains("\\Deleted") == true)
            }
            #expect(try h.store.pendingActions().isEmpty)
            try await syncer.sync(try h.folder(.trash).id)
            #expect(try h.rows(.trash).map(\.subject) == ["stays"])
        }
    }

    @Test func actionsRunBeforeAFolderIsSynced() async throws {
        let server = await standardServer()
        await server.deliver(mail("moving"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try #require(try h.rows(.inbox).first?.id)
            try h.store.apply(.delete(id))
            // Syncing the source first must not bring the message back.
            try await syncer.sync(try h.folder(.inbox).id)
            #expect(try h.rows(.inbox).isEmpty)
            #expect(await server.messages(in: "Trash").count == 1)
        }
    }
}
