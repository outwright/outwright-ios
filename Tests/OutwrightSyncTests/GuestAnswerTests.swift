// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

/// A guest's REPLY by mail to the owner's meeting, written to it where the CalDAV server does not
/// take REPLYs itself (RFC 6638 › 3.2.2.3): only for a real occurrence, never over a newer answer,
/// never at the cost of the owner's own unsettled change.
@Suite struct GuestAnswerTests {
    @Test func aGuestsAnswerByMailIsWrittenToTheMeeting() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(
                h.details(["bo@example.org", "cy@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let uid = try await h.serverMeeting().uid
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED")
            try await h.round()

            let held = try await h.serverMeeting().partstats
            #expect(held["bo@example.org"] == "ACCEPTED")
            #expect(held["cy@example.org"] == "NEEDS-ACTION")
            let shown = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            let bo = shown.first?.occurrence.details.attendees.first { $0.email.lowercased() == "bo@example.org" }
            #expect(bo?.response == .accepted)
            // An answer is no change to the meeting: the guests are not mailed again.
            #expect(try await h.sent().map(\.method) == ["REQUEST"])
        }
    }

    @Test func anAnswerFromSomeoneElseOrForAnOlderVersionIsNotTaken() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            try h.store.updateEvent(try h.event(), h.details(["bo@example.org"], title: "Moved"), rule: nil, scope: .event)
            try await h.round()
            let uid = try await h.serverMeeting().uid
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED", sequence: 0)
            try await h.replyArrives(
                uid: uid, from: "bo@example.org", partstat: "DECLINED", sequence: 1, sender: "eve@example.org")
            try await h.round()

            #expect(try await h.serverMeeting().partstats["bo@example.org"] == "NEEDS-ACTION")
        }
    }

    @Test func aServerThatSchedulesTakesTheAnswerItselfSoTheAppWritesNothing() async throws {
        try await withMeetings(schedules: true) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let uid = try await h.serverMeeting().uid
            let puts = await h.caldav.requests.filter { $0.method == "PUT" }.count
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED")
            try await h.round()

            #expect(await h.caldav.requests.filter { $0.method == "PUT" }.count == puts)
        }
    }

    /// The owner's weekly meeting with bo, four times from tomorrow, on the server; its UID.
    private func weekly(_ h: MeetingHarness) async throws -> String {
        _ = try h.store.createEvent(
            h.details(["bo@example.org"]), rule: RecurrenceRule.parse("FREQ=WEEKLY;COUNT=4"), in: try h.calendar())
        try await h.round()
        return try await h.serverMeeting().uid
    }

    private static let first = fixedNow.addingTimeInterval(86_400)
    private static let second = first.addingTimeInterval(7 * 86_400)

    @Test func anAnswerForAnOccurrenceTheMeetingDoesNotHaveIsNotTaken() async throws {
        try await withMeetings(schedules: false) { h in
            let uid = try await weekly(h)
            try await h.replyArrives(
                uid: uid, from: "bo@example.org", partstat: "ACCEPTED", occurrence: Self.first.addingTimeInterval(86_400))
            try await h.round()
            #expect(try await h.serverAnswers(of: "bo@example.org").keys.sorted() == [""])

            let shown = try h.store.occurrences(
                from: Self.second.addingTimeInterval(-3_600), to: Self.second.addingTimeInterval(3_600), in: nil)
            try h.store.deleteEvent(try #require(shown.first).id, scope: .occurrence(.utc(Self.second)))
            try await h.round()
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED", occurrence: Self.second)
            try await h.round()
            #expect(try await h.serverAnswers(of: "bo@example.org").keys.sorted() == [""])
        }
    }

    @Test func aSeriesAnswerLeavesTheGuestsAnswerForOneOccurrence() async throws {
        try await withMeetings(schedules: false) { h in
            let uid = try await weekly(h)
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "DECLINED", occurrence: Self.second)
            try await h.round()
            try await h.replyArrives(
                uid: uid, from: "bo@example.org", partstat: "ACCEPTED", stamp: "20261101T100000Z")
            try await h.round()

            #expect(try await h.serverAnswers(of: "bo@example.org") == ["": "ACCEPTED", utcText(Self.second): "DECLINED"])
        }
    }

    @Test func anOlderAnswerOfTheSameVersionDoesNotOverwriteANewerOne() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let uid = try await h.serverMeeting().uid
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "DECLINED", stamp: "20261101T100000Z")
            try await h.round()
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED", stamp: "20261101T090000Z")
            try await h.round()

            #expect(try await h.serverMeeting().partstats["bo@example.org"] == "DECLINED")
        }
    }

    /// The meeting changed on the server by another client: its title.
    private func changedElsewhere(_ h: MeetingHarness) async throws {
        let (name, ics) = try #require(await h.caldav.events(in: h.work).first)
        let changed = ics.replacingOccurrences(of: "SUMMARY:Planning", with: "SUMMARY:Elsewhere")
        await h.caldav.putEvent(changed, uid: name, in: h.work)
    }

    @Test func anAnswerMeetingAChangeMadeElsewhereIsWrittenOverIt() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let uid = try await h.serverMeeting().uid
            try await changedElsewhere(h)
            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED")
            try await h.round()
            try await h.round()

            #expect(try await h.serverMeeting().partstats["bo@example.org"] == "ACCEPTED")
            let ics = try #require(await h.caldav.events(in: h.work).values.first)
            #expect(ics.contains("SUMMARY:Elsewhere"))
            let shown = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            #expect(shown.allSatisfy { $0.conflict == nil && !$0.changeFailed })
        }
    }

    @Test func anAnswerLeavesTheOwnersUnsettledConflict() async throws {
        try await withMeetings(schedules: false) { h in
            _ = try h.store.createEvent(h.details(["bo@example.org"]), rule: nil, in: try h.calendar())
            try await h.round()
            let uid = try await h.serverMeeting().uid
            try await changedElsewhere(h)
            try h.store.updateEvent(try h.event(), h.details(["bo@example.org"], title: "Mine"), rule: nil, scope: .event)
            try await h.round()
            let conflicted = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            #expect(conflicted.first?.conflict != nil)

            try await h.replyArrives(uid: uid, from: "bo@example.org", partstat: "ACCEPTED")
            try await h.round()
            let shown = try h.store.occurrences(from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            #expect(shown.first?.conflict != nil)
        }
    }
}
