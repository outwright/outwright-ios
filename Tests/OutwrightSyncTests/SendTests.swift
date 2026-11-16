// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightIMAP
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

@Suite struct SendTests {
    /// A drop while the owner's copy goes to Sent: before the server stored it, or after.
    @Test(arguments: [false, true]) func aDropAfterSendingStillFilesExactlyOneSentCopy(afterStoring: Bool) async throws {
        let server = await standardServer()
        let data = try draftData()
        let serverDraft = await server.deliver(data, to: "Drafts", flags: ["\\Draft", "\\Seen"])
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: serverDraft, data: data)
            try h.store.apply(.send(draftID: id))
            await server.dropAtAppend(to: "Sent", afterStoring: afterStoring)
            try? await syncer.runActions()
            await syncer.disconnect()
            try await syncer.runActions()
            try await syncer.sync(try h.folder(.sent).id)

            #expect(await h.smtp.received.count == 1)
            #expect(await server.messages(in: "Sent").count == 1)
            #expect(try h.rows(.sent).count == 1)
            #expect(await server.messages(in: "Drafts").isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// A server without Drafts: the folder made here is not on the server until something is saved
    /// to it, so a message sent from it straight away is filed in Sent without looking there.
    @Test func aSendFromDraftsNotYetOnTheServerIsFiled() async throws {
        let server = FakeIMAPServer()
        await server.addFolder("Sent", specialUse: "\\Sent")
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()

            #expect(await h.smtp.received.count == 1)
            #expect(await server.messages(in: "Sent").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func theSentCopyIsShownAtOnceUnderTheDraftsID() async throws {
        let server = await standardServer(offersUIDPlus: true)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()
            let row = try #require(try h.store.message(id))
            #expect(row.folderID == (try h.folder(.sent)).id)
            #expect(row.uid == (await server.messages(in: "Sent")).first?.uid)
        }
    }

    @Test func aPermanentRefusalKeepsTheDraftMarkedAndLetsLaterChangesRun() async throws {
        let smtp = FakeSMTPServer(rejectRecipient: "cy@example.org", rejectCode: 550)
        try await withHarness(smtp: smtp) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            try h.store.apply(.saveDraft(id))
            await #expect(throws: SyncError.self) { try await syncer.runActions() }

            #expect(try h.store.pendingActions().isEmpty)
            let draft = try #require(try h.store.message(id))
            #expect(draft.folderID == (try h.folder(.drafts)).id)
            #expect(draft.notSent == .recipientRefused)
            #expect(await h.imap.messages(in: "Drafts").count == 1)
            #expect(await h.imap.messages(in: "Sent").isEmpty)
            #expect(await h.smtp.received.isEmpty)

            // Sent again, the mark goes.
            try h.store.apply(.send(draftID: id))
            #expect(try h.store.message(id)?.notSent == nil)
        }
    }

    /// #2: a server that refuses the session (a 5xx greeting or EHLO) has said nothing about the
    /// message: the send waits for the next try and the draft is not marked.
    @Test(arguments: [(554, 250), (220, 550)]) func aRefusedSessionLeavesTheSendQueued(
        greeting: Int, ehlo: Int
    ) async throws {
        let smtp = FakeSMTPServer(greetingCode: greeting, ehloCode: ehlo)
        try await withHarness(smtp: smtp) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            await #expect(throws: SyncError.self) { try await syncer.runActions() }

            #expect(try h.store.message(id)?.notSent == nil)
            #expect(try h.store.pendingActions().count == 1)
        }
    }

    /// #3: the owner's copy goes to Sent though its row was moved before it was filed; the move
    /// then takes that copy, so the server ends with one, where the owner put it.
    /// With and without a copy the server filed of its own, with and without APPENDUID.
    @Test(arguments: [(true, true), (false, true), (false, false)])
    func theSentCopyIsFiledInSentThoughItsRowMovedMeanwhile(serverFilesItsOwn: Bool, uidPlus: Bool) async throws {
        let server = await standardServer(offersUIDPlus: uidPlus)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            // Filing is refused this time, and meanwhile the server may file a copy of its own.
            await server.refuseNextAppend(to: "Sent")
            try? await syncer.runActions()
            if serverFilesItsOwn {
                let wire = try #require(await h.smtp.received.first?.data)
                await server.deliver(wire, to: "Sent", flags: ["\\Seen"])
            }
            try h.store.apply(.move(id, to: .archive))
            try await syncer.runActions()

            #expect(await h.smtp.received.count == 1)
            #expect(await server.messages(in: "Sent").isEmpty)
            #expect(await server.messages(in: "Archive").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// A sent message moved away and back before its copy was filed keeps the uid of the copy the
    /// server ends with.
    @Test func aSentMessageMovedAwayAndBackKeepsTheUIDOfItsCopy() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            await server.refuseNextAppend(to: "Sent")
            try? await syncer.runActions()
            try h.store.apply(.move(id, to: .archive))
            try h.store.apply(.moveTo(id, try h.folder(.sent).id))
            try await syncer.runActions()

            let copies = await server.messages(in: "Sent")
            #expect(copies.count == 1)
            #expect(await server.messages(in: "Archive").isEmpty)
            #expect(try h.store.message(id)?.uid == copies.first?.uid)
        }
    }

    /// A Sent made here that the server refused, with a copy waiting to be filed, gives way to
    /// the server's own Sent once that shows up: the copy is filed there, and there is one Sent.
    @Test func aSentMadeHereGivesWayToTheServersOwnOnceItShowsUp() async throws {
        let server = FakeIMAPServer()
        await server.keepFoldersUnderInbox(announcingNamespace: false)
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            await #expect(throws: SyncError.self) { try await syncer.runActions() }

            await server.addFolder("INBOX.Sent", specialUse: "\\Sent")
            await server.addFolder("INBOX.Drafts", specialUse: "\\Drafts")
            try await syncer.syncFolders()
            try await syncer.runActions()

            #expect(await h.smtp.received.count == 1)
            #expect(await server.messages(in: "INBOX.Sent").count == 1)
            #expect(try h.store.pendingActions().isEmpty)
            #expect(try h.store.folders(h.account.id).filter { $0.kind == .sent }.map(\.path) == ["INBOX.Sent"])
            #expect(try h.store.message(id)?.folderID == (try h.folder(.sent)).id)
        }
    }

    /// A flag set before the copy was filed moves nothing: the row takes the copy's uid at once.
    @Test func aSentMessageFlaggedBeforeFilingTakesTheUIDOfItsCopy() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = try await synced(h)
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.apply(.send(draftID: id))
            await server.refuseNextAppend(to: "Sent")
            try? await syncer.runActions()
            try h.store.apply(.setFlagged(id, true))
            try await syncer.runActions()

            let copies = await server.messages(in: "Sent")
            #expect(copies.count == 1)
            #expect(try h.store.message(id)?.uid == copies.first?.uid)
        }
    }

    /// A draft whose kept Message-ID cannot be written (too long) still goes, under one made for it.
    @Test func aDraftWithAnUnwritableMessageIDStillGoes() async throws {
        try await withHarness { h in
            let syncer = try await synced(h)
            let long = String(repeating: "x", count: 1_000) + "@example.org"
            let raw = Data(("From: jk@example.org\r\nTo: bo@example.org\r\nSubject: Plans\r\nMessage-ID: <\(long)>\r\n"
                + "MIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nSee you\r\n").utf8)
            let id = try localDraft(h, uid: 0, data: raw, header: long)
            try h.store.apply(.send(draftID: id))
            try await syncer.runActions()

            #expect(await h.smtp.received.count == 1)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }
}

@Suite struct DraftCalendarPartTests {
    /// A text-only draft carrying `ics` as the attachment `invite.ics`.
    private static func draft(_ method: String) throws -> MIMEMessage {
        let ics = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "METHOD:\(method)", "BEGIN:VEVENT",
            "UID:d1@example.org", "DTSTAMP:20261101T080000Z", "DTSTART:20261110T080000Z", "SUMMARY:Planning",
            "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n")
        let lines = [
            "From: jk@example.org", "To: bo@example.org", "Subject: Planning", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"b1\"", "",
            "--b1", "Content-Type: text/plain; charset=utf-8", "", "See the file.", "",
            "--b1", "Content-Type: text/calendar; charset=utf-8; name=\"invite.ics\"",
            "Content-Disposition: attachment; filename=\"invite.ics\"", "", ics, "--b1--", "",
        ]
        return try MIMEParser.parse(Data(lines.joined(separator: "\r\n").utf8))
    }

    @Test func aDraftsAttachedCalendarFileStaysAnAttachment() throws {
        let (calendar, attachments) = ActionRunner.calendarAndAttachments(try Self.draft("PUBLISH"))
        #expect(calendar == nil)
        #expect(attachments.map(\.filename) == ["invite.ics"])
    }

    @Test func aDraftsReplyIsItsCalendarPart() throws {
        let (calendar, attachments) = ActionRunner.calendarAndAttachments(try Self.draft("REPLY"))
        #expect(calendar?.method == "REPLY")
        #expect(attachments.isEmpty)
    }
}
