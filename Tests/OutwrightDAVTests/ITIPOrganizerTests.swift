// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

/// The organiser's side of iTIP: who the app mails, and the REQUEST and CANCEL it mails them.
@Suite struct ITIPOrganizerTests {
    static let me = "me@example.org"
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// The owner's own meeting, as the app writes it: the owner the ORGANIZER and an ATTENDEE too,
    /// two guests, an alarm of the owner's, and what a scheduling server adds.
    static func meeting(sequence: Int = 1, guests: [String] = ["bo@example.org", "cy@example.org"],
                        guestAgent: String? = nil, override: Bool = false,
                        overrideGuests: [String]? = nil) throws -> ICalComponent {
        let agent = guestAgent.map { ";SCHEDULE-AGENT=\($0)" } ?? ""
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Outwright//Outwright//EN",
            "BEGIN:VEVENT", "UID:m1@example.org", "DTSTAMP:20261101T080000Z", "SEQUENCE:\(sequence)",
            "DTSTART:20261112T130000Z", "DTEND:20261112T140000Z", "SUMMARY:Review",
            "RRULE:FREQ=WEEKLY", "X-MOZ-LASTACK:20261101T080000Z",
            "ORGANIZER;CN=Me;SCHEDULE-STATUS=1.2;X-OWN=1:mailto:\(me)",
            "ATTENDEE;PARTSTAT=ACCEPTED:mailto:\(me)",
        ]
        lines += guests.map { "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;SCHEDULE-STATUS=1.2\(agent):mailto:\($0)" }
        lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM", "END:VEVENT"]
        if override {
            lines += [
                "BEGIN:VEVENT", "UID:m1@example.org", "RECURRENCE-ID:20261119T130000Z", "SEQUENCE:\(sequence)",
                "DTSTAMP:20261101T080000Z", "DTSTART:20261119T150000Z", "DTEND:20261119T160000Z",
                "SUMMARY:Review", "ORGANIZER:mailto:\(me)",
            ] + (overrideGuests ?? guests).map { "ATTENDEE:mailto:\($0)" } + ["END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return try ICalendarReader.calendar(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
    }

    @Test func theAppMailsTheGuestsOnlyWhereTheServerDoesNotSchedule() throws {
        let meeting = try Self.meeting()
        #expect(ITIP.mailedAttendees(meeting, ownEmail: Self.me, serverSchedules: false)
            == ["bo@example.org", "cy@example.org"])
        #expect(ITIP.mailedAttendees(meeting, ownEmail: "ME@example.org", serverSchedules: false).count == 2)
        #expect(ITIP.mailedAttendees(meeting, ownEmail: Self.me, serverSchedules: true).isEmpty)
    }

    @Test func aGuestTheClientSchedulesIsMailedAndOneNobodySchedulesIsNot() throws {
        let client = try Self.meeting(guestAgent: "CLIENT")
        #expect(ITIP.mailedAttendees(client, ownEmail: Self.me, serverSchedules: true).count == 2)
        let none = try Self.meeting(guestAgent: "NONE")
        #expect(ITIP.mailedAttendees(none, ownEmail: Self.me, serverSchedules: false).isEmpty)
    }

    @Test func nobodyIsMailedForAMeetingSomeoneElseOrganises() throws {
        let meeting = try Self.meeting()
        #expect(ITIP.mailedAttendees(meeting, ownEmail: "bo@example.org", serverSchedules: false).isEmpty)
    }

    @Test func aGuestOnlyInAnOccurrenceIsMailedOnce() throws {
        let meeting = try Self.meeting(override: true)
        #expect(ITIP.mailedAttendees(meeting, ownEmail: Self.me, serverSchedules: false)
            == ["bo@example.org", "cy@example.org"])
    }

    @Test func theRequestIsTheWholeMeetingWithoutWhatIsTheOwnersOwn() throws {
        let sent = ITIP.requests(
            from: try Self.meeting(override: true), guests: ["bo@example.org", "cy@example.org"], now: now)
        #expect(sent.map(\.guests) == [["bo@example.org", "cy@example.org"]])
        let request = try #require(sent.first?.calendar)
        #expect(request.first("METHOD")?.value == "REQUEST")
        let events = request.components.filter { $0.name == "VEVENT" }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.components.isEmpty })
        let lines = events.flatMap(\.properties)
        #expect(!lines.contains { $0.parameters.contains { $0.name.hasPrefix("SCHEDULE-") || $0.name.hasPrefix("X-") } })
        #expect(!lines.contains { $0.name.hasPrefix("X-") })
        #expect(events.allSatisfy { $0.first("DTSTAMP")?.value == ICalTime.format(now, form: .utc) })
        #expect(events.first?.first("SEQUENCE")?.value == "1")
        let read = try #require(ITIP.read(ICalendarWriter.write(request), method: ""))
        #expect(read.method == .request)
        #expect(ITIP.senderMayApply(read, from: Self.me))
    }

    @Test func aGuestOfOneOccurrenceIsSentThatOccurrenceAlone() throws {
        let meeting = try Self.meeting(
            guests: ["bo@example.org"], override: true, overrideGuests: ["bo@example.org", "dee@example.org"])
        let sent = ITIP.requests(from: meeting, guests: ["bo@example.org", "dee@example.org"], now: now)
        #expect(sent.map(\.guests) == [["bo@example.org"], ["dee@example.org"]])
        let deesRequest = try #require(sent.last?.calendar)
        let dees = deesRequest.components.filter { $0.name == "VEVENT" }
        #expect(dees.count == 1)
        #expect(dees.first?.first("RECURRENCE-ID")?.value == "20261119T130000Z")
        let bos = try #require(sent.first?.calendar)
        #expect(bos.components.filter { $0.name == "VEVENT" }.count == 2)
    }

    @Test func aGuestTakenOffOneOccurrenceGetsItsCancel() throws {
        let meeting = try Self.meeting(sequence: 2, override: true, overrideGuests: ["bo@example.org"])
        let cancels = ITIP.occurrenceCancels(
            from: meeting, guests: ["bo@example.org", "cy@example.org"], now: now)
        #expect(cancels.map(\.guests) == [["cy@example.org"]])
        let event = try #require(cancels.first?.calendar.components.first { $0.name == "VEVENT" })
        #expect(event.first("RECURRENCE-ID")?.value == "20261119T130000Z")
        #expect(event.first("STATUS")?.value == "CANCELLED")
        #expect(event.first("SEQUENCE")?.value == "2")
        #expect(event.all("ATTENDEE").map(\.value) == ["mailto:cy@example.org"])
        let first = try #require(cancels.first?.calendar)
        let read = try #require(ITIP.read(ICalendarWriter.write(first), method: ""))
        #expect(read.method == .cancel)
        #expect(read.recurrenceID?.value == "20261119T130000Z")
    }

    @Test func noOccurrenceCancelWhenEveryGuestIsOnEveryOccurrence() throws {
        let meeting = try Self.meeting(override: true)
        #expect(ITIP.occurrenceCancels(from: meeting, guests: ["bo@example.org", "cy@example.org"], now: now).isEmpty)
    }

    @Test func noRequestForAMeetingWithoutOrganiser() throws {
        var meeting = try Self.meeting()
        meeting.components = meeting.components.map { $0.replacing("ORGANIZER", with: []) }
        #expect(ITIP.requests(from: meeting, guests: ["bo@example.org"], now: now).isEmpty)
    }

    @Test func theCancelEndsTheWholeMeetingForTheGuestsNamed() throws {
        let cancel = try #require(
            ITIP.cancel(from: try Self.meeting(sequence: 3, override: true), attendees: ["cy@example.org"],
                        raisingSequence: true, now: now))
        #expect(cancel.first("METHOD")?.value == "CANCEL")
        let events = cancel.components.filter { $0.name == "VEVENT" }
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.first("RECURRENCE-ID") == nil)
        #expect(event.first("STATUS")?.value == "CANCELLED")
        #expect(event.first("SEQUENCE")?.value == "4")
        #expect(event.all("ATTENDEE").map(\.value) == ["mailto:cy@example.org"])
        #expect(!event.properties.contains { $0.parameters.contains { $0.name.hasPrefix("X-") } })
        let read = try #require(ITIP.read(ICalendarWriter.write(cancel), method: ""))
        #expect(read.method == .cancel)
        #expect(ITIP.senderMayApply(read, from: Self.me))
    }

    @Test func aCancelForGuestsTakenOffKeepsTheSequenceTheUpdateRaised() throws {
        let cancel = try #require(
            ITIP.cancel(from: try Self.meeting(sequence: 3), attendees: ["dee@example.org"],
                        raisingSequence: false, now: now))
        let event = try #require(cancel.components.first { $0.name == "VEVENT" })
        #expect(event.first("SEQUENCE")?.value == "3")
    }

    @Test func noCancelForNobody() throws {
        #expect(ITIP.cancel(from: try Self.meeting(), attendees: [], raisingSequence: true, now: now) == nil)
    }
}
