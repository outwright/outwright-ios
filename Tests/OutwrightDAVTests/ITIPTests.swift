// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

@Suite struct ITIPTests {
    typealias F = ITIPFixtures
    let me = ITIPFixtures.me

    func read(_ data: Data, method: String = "") throws -> ITIPMessage {
        try #require(ITIP.read(data, method: method))
    }

    func events(_ calendar: ICalComponent) -> [ICalComponent] {
        calendar.components.filter { $0.name == "VEVENT" }
    }

    func own(_ event: ICalComponent?) -> ICalProperty? {
        event?.all("ATTENDEE").first { $0.value.lowercased() == "mailto:" + me }
    }

    /// A stored copy: the invitation applied to nothing.
    func stored(_ data: Data) throws -> ICalComponent {
        ITIP.applying(try read(data), to: nil, ownEmail: me)
    }

    // MARK: - Reading

    @Test func readsTheThreeShapes() throws {
        let outlook = try read(F.outlook())
        #expect(outlook.method == .request)
        #expect(outlook.uid == "040000008200E00074C5B7101A82E00800000000outlook1")
        #expect(outlook.sequence == 0)
        #expect(outlook.organizer == "org@example.org")
        #expect(outlook.attendees.map(\.email) == ["me@example.org", "bo@example.org"])
        #expect(outlook.attendees.map(\.partstat) == ["NEEDS-ACTION", "NEEDS-ACTION"])
        #expect(outlook.recurrenceID == nil)

        let google = try read(F.google())
        #expect(google.method == .request)
        #expect(google.uid == "g1@google.example.org")
        #expect(google.organizer == "org@example.org")
        #expect(google.attendees.map(\.partstat) == ["ACCEPTED", "NEEDS-ACTION"])

        let stalwart = try read(F.stalwart())
        #expect(stalwart.sequence == 2)
        #expect(stalwart.attendees.map(\.email) == ["me@example.org", "cy@example.org"])
    }

    @Test func methodFromBodyWinsOverContentType() throws {
        #expect(try read(F.outlook(method: "CANCEL"), method: "REQUEST").method == .cancel)
        let bare = F.ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:x@example.org", "END:VEVENT", "END:VCALENDAR"])
        #expect(try read(bare, method: "add").method == .add)
        #expect(ITIP.read(bare, method: "") == nil)
        #expect(ITIP.read(F.outlook(method: "PUBLISH"), method: "REQUEST") == nil)
        #expect(ITIP.read(F.outlook(method: "COUNTER"), method: "") == nil)
    }

    @Test func twoUidsIsRefused() {
        let data = F.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST",
            "BEGIN:VEVENT", "UID:a@example.org", "END:VEVENT",
            "BEGIN:VEVENT", "UID:b@example.org", "END:VEVENT",
            "END:VCALENDAR",
        ])
        #expect(ITIP.read(data, method: "REQUEST") == nil)
        let missing = F.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST",
            "BEGIN:VEVENT", "UID:a@example.org", "END:VEVENT", "BEGIN:VEVENT", "END:VEVENT",
            "END:VCALENDAR",
        ])
        #expect(ITIP.read(missing, method: "REQUEST") == nil)
    }

    @Test func noVeventIsRefused() {
        let todo = F.ics(["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VTODO", "UID:t@example.org", "END:VTODO",
                          "END:VCALENDAR"])
        #expect(ITIP.read(todo, method: "REQUEST") == nil)
        #expect(ITIP.read(Data("not a calendar".utf8), method: "REQUEST") == nil)
    }

    // MARK: - Who may apply it

    @Test func organizerMayCancelOthersMayNot() throws {
        let cancel = try read(F.outlook(method: "CANCEL"))
        #expect(ITIP.senderMayApply(cancel, from: "org@example.org"))
        #expect(!ITIP.senderMayApply(cancel, from: "bo@example.org"))
        #expect(!ITIP.senderMayApply(cancel, from: ""))
        let noOrganizer = F.ics(["BEGIN:VCALENDAR", "METHOD:CANCEL", "BEGIN:VEVENT", "UID:x@example.org",
                                 "END:VEVENT", "END:VCALENDAR"])
        #expect(!ITIP.senderMayApply(try read(noOrganizer), from: "org@example.org"))
    }

    @Test func replyNeedsTheReplyingAttendee() throws {
        let reply = try read(F.reply())
        #expect(ITIP.senderMayApply(reply, from: "bo@example.org"))
        #expect(!ITIP.senderMayApply(reply, from: "me@example.org"))
        let two = try read(F.reply(extraAttendee: true))
        #expect(!ITIP.senderMayApply(two, from: "bo@example.org"))
    }

    @Test func senderCompareIgnoresCase() throws {
        #expect(ITIP.senderMayApply(try read(F.outlook()), from: "ORG@Example.ORG"))
        #expect(ITIP.senderMayApply(try read(F.reply(from: "Bo@Example.org")), from: "bo@EXAMPLE.org"))
    }

    // MARK: - Newer

    @Test func newerBySequenceThenDtstamp() throws {
        let base = try stored(F.outlook(sequence: 1, stamp: "20261101T120000Z"))
        #expect(ITIP.isNewer(try read(F.outlook(sequence: 2, stamp: "20261101T110000Z")), than: base))
        #expect(!ITIP.isNewer(try read(F.outlook(sequence: 0, stamp: "20261105T120000Z")), than: base))
        #expect(ITIP.isNewer(try read(F.outlook(sequence: 1, stamp: "20261101T130000Z")), than: base))
        #expect(!ITIP.isNewer(try read(F.outlook(sequence: 1, stamp: "20261101T120000Z")), than: base))
    }

    // MARK: - Applying

    @Test func timeChangeResetsPartstat() throws {
        let accepted = ITIP.settingPartstat("ACCEPTED", in: try stored(F.outlook()), ownEmail: me, recurrenceID: nil)
        let moved = try read(F.outlook(sequence: 1, start: "20261109T110000", end: "20261109T120000"))
        let result = ITIP.applying(moved, to: accepted, ownEmail: me)
        let event = events(result).first
        #expect(own(event)?.parameter("PARTSTAT") == "NEEDS-ACTION")
        #expect(event?.first("DTSTART")?.value == "20261109T110000")
        #expect(event?.first("SEQUENCE")?.value == "1")
    }

    @Test func placeChangeKeepsPartstat() throws {
        let accepted = ITIP.settingPartstat("ACCEPTED", in: try stored(F.outlook()), ownEmail: me, recurrenceID: nil)
        let elsewhere = try read(F.outlook(sequence: 1, location: "Room 2"))
        let event = events(ITIP.applying(elsewhere, to: accepted, ownEmail: me)).first
        #expect(own(event)?.parameter("PARTSTAT") == "ACCEPTED")
        #expect(event?.first("LOCATION")?.text == "Room 2")
    }

    @Test func updateKeepsOwnAlarm() throws {
        var mine = try stored(F.outlook())
        let alarm = ICalComponent(name: "VALARM", properties: [
            ICalProperty(name: "ACTION", value: "DISPLAY"), ICalProperty(name: "TRIGGER", value: "-PT1H"),
        ])
        if let index = mine.components.firstIndex(where: { $0.name == "VEVENT" }) {
            mine.components[index].components = [alarm]
        }
        let update = try read(F.outlook(sequence: 1, location: "Room 2"))
        let event = events(ITIP.applying(update, to: mine, ownEmail: me)).first
        #expect(event?.components.filter { $0.name == "VALARM" } == [alarm])
    }

    @Test func requestForAnOccurrenceAddsAnOverrideBesideTheSeries() throws {
        let series = try stored(F.google())
        let occurrence = F.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST",
            "BEGIN:VEVENT", "UID:g1@google.example.org", "RECURRENCE-ID:20261117T080000Z",
            "DTSTART:20261117T090000Z", "DTEND:20261117T093000Z", "SEQUENCE:1", "DTSTAMP:20261105T080000Z",
            "ORGANIZER:mailto:org@example.org", "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.org",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let message = try read(occurrence)
        #expect(message.recurrenceID?.value == "20261117T080000Z")
        let result = ITIP.applying(message, to: series, ownEmail: me)
        #expect(events(result).count == 2)
        #expect(events(result).first?.first("RRULE") != nil)
        #expect(events(result).last?.first("DTSTART")?.value == "20261117T090000Z")
    }

    @Test func cancelOneOccurrenceMarksOnlyIt() throws {
        let series = try stored(F.google())
        let cancel = try read(F.googleCancel(recurrenceID: "20261117T080000Z"))
        let result = ITIP.applying(cancel, to: series, ownEmail: me)
        let all = events(result)
        #expect(all.count == 2)
        let master = all.first { $0.first("RECURRENCE-ID") == nil }
        let override = all.first { $0.first("RECURRENCE-ID")?.value == "20261117T080000Z" }
        #expect(master?.first("STATUS")?.value == "CONFIRMED")
        #expect(override?.first("STATUS")?.value == "CANCELLED")
        #expect(override?.first("DTSTART")?.value == "20261117T080000Z")
        #expect(override?.first("RRULE") == nil)
    }

    @Test func cancelWholeSeries() throws {
        var series = try stored(F.google())
        series.components.append(ICalComponent(name: "VEVENT", properties: [
            ICalProperty(name: "UID", value: "g1@google.example.org"),
            ICalProperty(name: "RECURRENCE-ID", value: "20261124T080000Z"),
            ICalProperty(name: "DTSTART", value: "20261124T100000Z"),
        ]))
        let result = ITIP.applying(try read(F.googleCancel(recurrenceID: nil)), to: series, ownEmail: me)
        #expect(events(result).count == 2)
        #expect(events(result).allSatisfy { $0.first("STATUS")?.value == "CANCELLED" })
    }

    @Test func newInvitationHasNoMethodAndNeedsAction() throws {
        let result = try stored(F.outlook())
        #expect(result.first("METHOD") == nil)
        #expect(own(events(result).first)?.parameter("PARTSTAT") == "NEEDS-ACTION")
        let withoutPartstat = F.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST",
            "BEGIN:VEVENT", "UID:n@example.org", "ORGANIZER:mailto:org@example.org", "ATTENDEE:mailto:me@example.org",
            "END:VEVENT", "END:VCALENDAR",
        ])
        #expect(own(events(try stored(withoutPartstat)).first)?.parameter("PARTSTAT") == "NEEDS-ACTION")
    }

    // MARK: - Answering

    @Test func partstatOnMasterLeavesEverythingElse() throws {
        let before = try stored(F.outlook())
        let after = ITIP.settingPartstat("accepted", in: before, ownEmail: me, recurrenceID: nil)
        let event = try #require(events(after).first)
        #expect(own(event)?.parameter("PARTSTAT") == "ACCEPTED")
        #expect(own(event)?.parameter("RSVP") == nil)
        #expect(own(event)?.parameter("CN") == "Me")
        // Everything else as it was read.
        let other = event.all("ATTENDEE").last
        #expect(other == events(before).first?.all("ATTENDEE").last)
        #expect(event.first("X-MICROSOFT-CDO-BUSYSTATUS")?.value == "TENTATIVE")
        #expect(event.first("SEQUENCE")?.value == "0")
        #expect(after.components.filter { $0.name == "VTIMEZONE" } == before.components.filter { $0.name == "VTIMEZONE" })
        var expected = events(before).first
        expected = expected?.replacing("ATTENDEE", with: event.all("ATTENDEE"))
        #expect(event == expected)
    }

    @Test func partstatOnOccurrenceCreatesOverride() throws {
        let series = try stored(F.google())
        let recurrence = ICalProperty(name: "RECURRENCE-ID", value: "20261117T080000Z")
        let after = ITIP.settingPartstat("DECLINED", in: series, ownEmail: me, recurrenceID: recurrence)
        let all = events(after)
        #expect(all.count == 2)
        let master = all.first { $0.first("RECURRENCE-ID") == nil }
        #expect(own(master)?.parameter("PARTSTAT") == "NEEDS-ACTION")
        let override = all.first { $0.first("RECURRENCE-ID") != nil }
        #expect(own(override)?.parameter("PARTSTAT") == "DECLINED")
        #expect(override?.first("DTSTART")?.value == "20261117T080000Z")
        #expect(override?.first("RRULE") == nil)
        #expect(override?.first("SUMMARY")?.text == "Weekly sync")
        // Answering it again changes the override, not a third copy.
        let again = ITIP.settingPartstat("ACCEPTED", in: after, ownEmail: me, recurrenceID: recurrence)
        #expect(events(again).count == 2)
    }

    @Test func anOverrideKeepsTheSeriesLengthWhenItCannotBeMeasured() throws {
        let recurrence = ICalProperty(name: "RECURRENCE-ID", value: "2026-11-17")
        for end in ["DTEND:20261110T083000Z", "DTEND:soon", "DURATION:PT30M"] {
            let series = try ICalendarReader.calendar(F.ics([
                "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:d@example.org", "DTSTART:20261110T080000Z", end,
                "RRULE:FREQ=WEEKLY", "ORGANIZER:mailto:org@example.org", "ATTENDEE:mailto:me@example.org",
                "END:VEVENT", "END:VCALENDAR",
            ]))
            let after = ITIP.settingPartstat("ACCEPTED", in: series, ownEmail: me, recurrenceID: recurrence)
            let override = events(after).first { $0.first("RECURRENCE-ID") != nil }
            let name = end.hasPrefix("DTEND") ? "DTEND" : "DURATION"
            #expect(override?.first(name) == events(series).first?.first(name))
        }
    }

    @Test func occurrenceReplyCarriesRecurrenceId() throws {
        let series = try stored(F.google())
        let recurrence = ICalProperty(name: "RECURRENCE-ID", value: "20261117T080000Z")
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let reply = try #require(ITIP.reply(from: series, ownEmail: me, partstat: "TENTATIVE",
                                            recurrenceID: recurrence, now: now))
        let event = try #require(events(reply).first)
        #expect(event.first("RECURRENCE-ID")?.value == "20261117T080000Z")
        #expect(event.first("DTSTART")?.value == "20261117T080000Z")
        #expect(event.first("DTEND")?.value == "20261117T083000Z")
        #expect(own(event)?.parameter("PARTSTAT") == "TENTATIVE")
    }

    @Test func replyHasOnlyOwnAttendeeAndNoDescription() throws {
        let mine = try stored(F.outlook(sequence: 3))
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let reply = try #require(ITIP.reply(from: mine, ownEmail: me, partstat: "ACCEPTED", recurrenceID: nil,
                                            now: now))
        #expect(reply.first("METHOD")?.value == "REPLY")
        #expect(reply.first("PRODID")?.value == "-//Outwright//Outwright//EN")
        let all = events(reply)
        #expect(all.count == 1)
        let event = try #require(all.first)
        #expect(event.first("UID")?.value == "040000008200E00074C5B7101A82E00800000000outlook1")
        #expect(event.first("SEQUENCE")?.value == "3")
        #expect(event.first("DTSTAMP")?.value == "20261026T073320Z")
        #expect(event.first("DTSTART")?.parameter("TZID") == "W. Europe Standard Time")
        #expect(event.first("DTEND") != nil)
        #expect(event.first("SUMMARY")?.text == "Planning")
        #expect(event.first("ORGANIZER")?.value == "mailto:org@example.org")
        #expect(event.all("ATTENDEE").count == 1)
        #expect(own(event)?.parameter("PARTSTAT") == "ACCEPTED")
        #expect(own(event)?.parameter("RSVP") == nil)
        for absent in ["DESCRIPTION", "ATTACH", "LOCATION", "X-MICROSOFT-CDO-BUSYSTATUS", "RECURRENCE-ID"] {
            #expect(event.first(absent) == nil)
        }
        #expect(event.components.isEmpty)
        // It reads back as a REPLY from the owner.
        let back = try read(ICalendarWriter.write(reply))
        #expect(back.method == .reply)
        #expect(ITIP.senderMayApply(back, from: me))
    }

    @Test func noReplyWithoutOrganizerOrOwnAttendee() throws {
        let now = Date()
        let mine = try stored(F.outlook())
        #expect(ITIP.reply(from: mine, ownEmail: "stranger@example.org", partstat: "ACCEPTED", recurrenceID: nil,
                           now: now) == nil)
        let own = F.ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:o@example.org", "ATTENDEE:mailto:me@example.org",
                         "END:VEVENT", "END:VCALENDAR"])
        let calendar = try ICalendarReader.calendar(own)
        #expect(ITIP.reply(from: calendar, ownEmail: me, partstat: "ACCEPTED", recurrenceID: nil, now: now) == nil)
    }

    @Test func scheduleAgentClientOnOrganizer() throws {
        let result = ITIP.settingScheduleAgentClient(try stored(F.stalwart()))
        let organizer = events(result).first?.first("ORGANIZER")
        #expect(organizer?.parameter("SCHEDULE-AGENT") == "CLIENT")
        #expect(organizer?.parameter("CN") == "Org")
        let twice = ITIP.settingScheduleAgentClient(result)
        #expect(events(twice).first?.first("ORGANIZER")?.parameters.filter { $0.name == "SCHEDULE-AGENT" }.count == 1)
    }

    @Test func theClientRepliesOnlyWhenTheOrganizerSaysSo() throws {
        let plain = try stored(F.stalwart())
        #expect(!ITIP.repliesByClient(plain))
        #expect(ITIP.repliesByClient(ITIP.settingScheduleAgentClient(plain)))
        let none = F.ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:n@example.org",
                          "ORGANIZER;SCHEDULE-AGENT=NONE:mailto:org@example.org", "END:VEVENT", "END:VCALENDAR"])
        #expect(!ITIP.repliesByClient(try ICalendarReader.calendar(none)))
    }

    /// RFC 6638 › 3.2.2.1: written over the owner's copy, the organiser's change keeps what is the
    /// owner's there: the ORGANIZER's SCHEDULE-AGENT, the alarms, and the answer while the time stays.
    @Test func theOrganisersChangeKeepsWhatIsTheOwnersInTheHeldCopy() throws {
        func event(start: String, organizer: String, partstat: String, alarm: Bool) throws -> ICalComponent {
            let reminder = alarm ? ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT5M", "END:VALARM"] : []
            return try ICalendarReader.calendar(F.ics(
                ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:k@example.org", "SEQUENCE:1", "DTSTART:\(start)",
                 "\(organizer):mailto:org@example.org", "ATTENDEE;PARTSTAT=\(partstat):mailto:\(me)"]
                    + reminder + ["END:VEVENT", "END:VCALENDAR"]))
        }
        let held = try event(
            start: "20261201T090000Z", organizer: "ORGANIZER;SCHEDULE-AGENT=CLIENT", partstat: "ACCEPTED", alarm: true)
        let retitled = try event(
            start: "20261201T090000Z", organizer: "ORGANIZER", partstat: "NEEDS-ACTION", alarm: false)
        let kept = ITIP.keepingOwn(retitled, from: held, ownEmail: me)
        #expect(ITIP.repliesByClient(kept))
        #expect(own(events(kept).first)?.parameter("PARTSTAT") == "ACCEPTED")
        #expect(events(kept).first?.components.map(\.name) == ["VALARM"])
        let moved = try event(
            start: "20261202T090000Z", organizer: "ORGANIZER", partstat: "NEEDS-ACTION", alarm: false)
        let reasked = ITIP.keepingOwn(moved, from: held, ownEmail: me)
        #expect(ITIP.repliesByClient(reasked))
        #expect(own(events(reasked).first)?.parameter("PARTSTAT") == "NEEDS-ACTION")
        #expect(events(reasked).first?.components.map(\.name) == ["VALARM"])
        let plain = try event(
            start: "20261201T090000Z", organizer: "ORGANIZER", partstat: "ACCEPTED", alarm: false)
        #expect(!ITIP.repliesByClient(ITIP.keepingOwn(ITIP.settingScheduleAgentClient(retitled), from: plain, ownEmail: me)))
    }
}
