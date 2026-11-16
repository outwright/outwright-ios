// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

private let uid = "meeting1@example.org"

/// The `iCalUId` Graph gives a meeting from outside Exchange: its GlobalObjectId, with the
/// invitation's UID embedded after `vCal-Uid` ([MS-OXCICAL] 2.1.3.1.1.20.26).
private var exchangeID: String {
    let data = Array("vCal-Uid".utf8) + [1, 0, 0, 0] + Array(uid.utf8) + [0]
    let classID: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00, 0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08]
    let length: [UInt8] = [UInt8(data.count), 0, 0, 0]
    let bytes = classID + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + length + data
    return bytes.map { String(format: "%02X", $0) }.joined()
}

/// An iMIP mail from boss@example.org inviting the account (or cancelling) the meeting `uid`.
private func invitationMail(to email: String, method: String = "REQUEST", sequence: Int = 0) -> Data {
    let ics = icsText([
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "METHOD:\(method)", "BEGIN:VEVENT", "UID:\(uid)",
        "DTSTAMP:20260301T080000Z", "SEQUENCE:\(sequence)", "DTSTART:20260304T130000Z", "DTEND:20260304T140000Z",
        "SUMMARY:Review", "ORGANIZER;CN=Boss:mailto:boss@example.org",
        "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(email)", "END:VEVENT", "END:VCALENDAR",
    ])
    let lines = [
        "From: Boss <boss@example.org>", "To: \(email)", "Subject: Invitation: Review",
        "Date: Thu, 05 Nov 2026 10:00:00 +0000", "Message-ID: <\(UUID().uuidString)@example.org>",
        "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"b1\"", "",
        "--b1", "Content-Type: text/plain; charset=utf-8", "", "You are invited.", "",
        "--b1", "Content-Type: text/calendar; charset=utf-8; method=\(method)", "", ics, "--b1--", "",
    ]
    return Data(lines.joined(separator: "\r\n").utf8)
}

extension GraphHarness {
    /// Exchange's copy of the meeting in the account's calendar, as the invitee holds it.
    func exchangeCopy() -> Data {
        graphEvent("Review", "2026-03-04T13:00:00", "2026-03-04T14:00:00", [
            "isOrganizer": false, "iCalUId": exchangeID,
            "organizer": ["emailAddress": ["address": "boss@example.org", "name": "Boss"]],
            "attendees": [["emailAddress": ["address": account.email], "type": "required"]],
            "responseStatus": ["response": "notResponded"],
        ])
    }

    /// Delivers the mail to the Inbox, brings it in and fetches its body: the row.
    func receive(_ data: Data) async throws -> MessageRow {
        await microsoft.mail.imap.deliver(data, to: "INBOX")
        let syncer = microsoft.syncer()
        try await syncer.syncFolders()
        let inbox = try #require(try store.folders(account.id).first { $0.path == "INBOX" })
        try await syncer.sync(inbox.id)
        let index = try store.folderIndex(inbox.id)
        let row = try #require(try index.keys.max().flatMap { index[$0] }.flatMap { try store.message($0) })
        try await syncer.fetchBody(row.id)
        return row
    }
}

/// Exchange puts an invitation in the calendar itself and answers through Graph: the mail's card
/// shows the meeting the calendar holds, and nothing is added to the calendar from the mail.
@Suite(.serialized) struct GraphInvitationTests {
    @Test func anInvitationMailShowsTheMeetingExchangeHolds() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(h.exchangeCopy(), in: home)
            try await h.calendarSyncer().sync()
            let row = try await h.receive(invitationMail(to: h.account.email))
            let state = try #require(try h.store.invitation(for: row.id))
            #expect(state.wasApplied)
            #expect(state.event?.id == (try h.heldEvent("Review").id))
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            #expect(try h.held().count == 1)
        }
    }

    @Test func anInvitationBeforeExchangesCopyWaitsForTheCalendar() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let row = try await h.receive(invitationMail(to: h.account.email))
            #expect(try !h.store.isInvitationRecorded(row.id))
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            await h.graph.putEvent(h.exchangeCopy(), in: home)
            try await syncer.sync()
            await h.microsoft.syncer().retakeInvitations()
            #expect(try h.store.isInvitationRecorded(row.id))
            #expect(try h.store.invitation(for: row.id)?.wasApplied == true)
            #expect(try h.store.invitation(for: row.id)?.event?.id == (try h.heldEvent("Review").id))
            #expect(try h.held().count == 1)
        }
    }

    /// A meeting Exchange still doesn't hold after a calendar sync (declined elsewhere, deleted, out
    /// of the window) never will: the mail waits no longer, so it isn't read again on every sync.
    @Test func anInvitationExchangeNeverHoldsWaitsOnce() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let row = try await h.receive(invitationMail(to: h.account.email))
            #expect(try !h.store.isInvitationRecorded(row.id))
            try await syncer.sync()
            await h.microsoft.syncer().retakeInvitations()
            #expect(try h.store.isInvitationRecorded(row.id))
            #expect(try h.store.invitation(for: row.id)?.wasApplied == false)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }
}

