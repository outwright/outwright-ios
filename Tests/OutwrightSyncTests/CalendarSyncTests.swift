// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

let stockholm = TimeZone(identifier: "Europe/Stockholm") ?? .gmt

/// A clock the test moves.
final class CalendarClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = fixedNow) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(days: Double) {
        current.withLock { $0 = $0.addingTimeInterval(days * 86_400) }
    }
}

/// Keeps every set of reminders handed to it.
actor RecordingReminders: Reminders {
    private(set) var replaced: [[PlannedReminder]] = []

    var last: [PlannedReminder] { replaced.last ?? [] }

    func authorization() async -> Bool { true }
    func requestAuthorization() async -> Bool { true }

    func replace(_ planned: [PlannedReminder]) async {
        replaced.append(planned)
    }
}

/// Reminders whose first `replace` is held until `release()`, the way the phone's notification centre can
/// be slow; keeps the set the last finished `replace` left.
actor GatedReminders: Reminders {
    private(set) var last: [PlannedReminder] = []
    private(set) var waiting = false
    private var released = false
    private var calls = 0

    func authorization() async -> Bool { true }
    func requestAuthorization() async -> Bool { true }

    func release() { released = true }

    func replace(_ planned: [PlannedReminder]) async {
        calls += 1
        if calls == 1 {
            waiting = true
            while !released { try? await Task.sleep(for: .milliseconds(10)) }
        }
        last = planned
    }
}

/// `yyyyMMddTHHmmssZ` of an instant.
func utcText(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
        format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
        parts.minute ?? 0, parts.second ?? 0)
}

/// A synthetic calendar object with one event, an hour long, starting `hours` after the tests' clock.
func eventText(
    _ uid: String, title: String, hours: Double = 24, rule: String? = nil, alarm: String? = nil,
    extra: [String] = []
) -> String {
    let start = fixedNow.addingTimeInterval(hours * 3_600)
    var lines = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN", "BEGIN:VEVENT", "UID:\(uid)",
        "DTSTAMP:20261101T080000Z", "DTSTART:\(utcText(start))", "DTEND:\(utcText(start.addingTimeInterval(3_600)))",
        "SUMMARY:\(title)",
    ]
    if let rule { lines.append("RRULE:\(rule)") }
    lines += extra
    if let alarm { lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:\(alarm)", "END:VALARM"] }
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return icsText(lines)
}

struct CalendarHarness {
    let server: FakeCalDAVServer
    let store: MailStore
    let secrets: InMemorySecretStore
    let account: Account
    let clock: CalendarClock

    func syncer() -> CalendarSyncer {
        let clock = clock
        return CalendarSyncer(
            account: account, store: store, secrets: secrets, session: URLSession(configuration: .ephemeral),
            now: { clock.now }, phoneZone: { stockholm })
    }

    /// Every occurrence held, in the store's window.
    func occurrences() throws -> [CalendarEvent] {
        try store.occurrences(
            from: fixedNow.addingTimeInterval(-400 * 86_400), to: fixedNow.addingTimeInterval(800 * 86_400), in: nil)
    }

    /// The titles of the events held, sorted, one per event.
    func titles() throws -> [String] {
        var seen: Set<EventID> = []
        return try occurrences().filter { seen.insert($0.id).inserted }.map(\.occurrence.details.title).sorted()
    }

    func event(titled title: String) throws -> CalendarEvent {
        try #require(try occurrences().first { $0.occurrence.details.title == title })
    }

    func calendar(named name: String) throws -> CalendarInfo {
        try #require(try store.calendars(account.id).first { $0.name == name })
    }

    /// The fake's objects of a calendar, read.
    func serverSeries(_ calendar: URL) async throws -> [EventSeries] {
        var found: [EventSeries] = []
        for text in await server.events(in: calendar).values {
            found += EventMapping.series(try ICalendarReader.calendar(Data(text.utf8)))
        }
        return found
    }
}

/// A fake CalDAV server and an in-memory store with an account pointed at it (or at nothing, with
/// `calDAV: false`).
func withCalendars(
    sync: Bool = true, calDAV: Bool = true, _ body: (CalendarHarness) async throws -> Void
) async throws {
    let server = FakeCalDAVServer(offersSyncCollection: sync)
    let port = try await server.start()
    do {
        let store = try MailStore(path: nil)
        var account = Account(
            id: AccountID(), displayName: "Jörgen", email: "jk@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            smtp: MailEndpoint(host: "127.0.0.1", port: 1, security: "plainLoopbackOnly"),
            user: "jk@example.org", signature: "", sortOrder: 0)
        account.calDAV = calDAV ? "http://127.0.0.1:\(port)/" : nil
        try store.save(account)
        let secrets = InMemorySecretStore()
        try secrets.setPassword(Secret("secret"), for: account.id)
        try await body(CalendarHarness(server: server, store: store, secrets: secrets, account: account, clock: CalendarClock()))
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

@Suite struct CalendarSyncTests {
    @Test func firstSyncBringsEveryEventCalendar() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            let home = await h.server.addCalendar("Home", color: "#FF8800")
            let tasks = await h.server.addCalendar("Tasks", components: ["VTODO"])
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "Dentist", hours: 30), uid: "b", in: home)
            await h.server.putEvent(eventText("c", title: "Weekly", hours: 2, rule: "FREQ=WEEKLY;COUNT=3"), uid: "c", in: home)
            await h.server.putEvent(eventText("t", title: "Not an event"), uid: "t", in: tasks)
            try await h.syncer().sync()
            let calendars = try h.store.calendars(h.account.id)
            #expect(calendars.map(\.name) == ["Home", "Work"])
            #expect(calendars.first?.color == 0xFF8800)
            #expect(try h.titles() == ["Dentist", "Planning", "Weekly"])
            #expect(try h.occurrences().filter { $0.occurrence.details.title == "Weekly" }.count == 3)
        }
    }

    @Test(arguments: [true, false]) func laterSyncAppliesChangesAndRemovals(sync: Bool) async throws {
        try await withCalendars(sync: sync) { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "Review"), uid: "b", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            #expect(try h.titles() == ["Planning", "Review"])

            await h.server.putEvent(eventText("a", title: "Planning (moved)", hours: 48), uid: "a", in: work)
            await h.server.removeEvent(uid: "b", in: work)
            await h.server.putEvent(eventText("c", title: "Retro"), uid: "c", in: work)
            try await syncer.sync()
            #expect(try h.titles() == ["Planning (moved)", "Retro"])
            let moved = try h.event(titled: "Planning (moved)")
            #expect(moved.occurrence.start == fixedNow.addingTimeInterval(48 * 3_600))
        }
    }

    @Test func invalidTokenFallsBackToFullListing() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "Review"), uid: "b", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            await h.server.forgetSyncTokens()
            await h.server.putEvent(eventText("a", title: "Planning 2"), uid: "a", in: work)
            await h.server.removeEvent(uid: "b", in: work)
            try await syncer.sync()
            #expect(try h.titles() == ["Planning 2"])
            // The new token works: nothing changed, nothing fetched.
            let asked = await h.server.multigets.count
            try await syncer.sync()
            #expect(await h.server.multigets.count == asked)
        }
    }

    @Test func serverWithoutSyncCollectionUsesETags() async throws {
        try await withCalendars(sync: false) { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "Review"), uid: "b", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            await h.server.putEvent(eventText("b", title: "Review 2"), uid: "b", in: work)
            try await syncer.sync()
            #expect(try h.titles() == ["Planning", "Review 2"])
            // Only the changed event was fetched.
            #expect(await h.server.multigets.last == ["/calendars/c1/b.ics"])
            #expect(await h.server.requests.contains { $0.method == "REPORT" })
        }
    }

    @Test func movedWindowListsAgain() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            // Two years ahead at noon: just past the window's end (two years from the start of today in
            // Stockholm), inside it a day later.
            let later = Calendar(identifier: .gregorian).date(byAdding: .year, value: 2, to: fixedNow) ?? fixedNow
            let hours = later.timeIntervalSince(fixedNow) / 3_600
            await h.server.putEvent(eventText("far", title: "Far ahead", hours: hours), uid: "far", in: work)
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            #expect(try h.titles() == ["Planning"])
            h.clock.advance(days: 1)
            try await syncer.sync()
            #expect(try h.titles() == ["Far ahead", "Planning"])
        }
    }

    @Test(arguments: [true, false]) func refusedObjectIsCountedAndNotFetchedAgain(sync: Bool) async throws {
        try await withCalendars(sync: sync) { h in
            let work = await h.server.addCalendar("Work")
            let alarms = Array(repeating: ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT5M", "END:VALARM"], count: 11)
            await h.server.putEvent(eventText("loud", title: "Too many alarms", extra: alarms.flatMap { $0 }), uid: "loud", in: work)
            // Cut short (and with a rule, so that the fake lists it).
            await h.server.putEvent("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:broken\r\nRRULE:FREQ=DAILY\r\n", uid: "broken", in: work)
            // A series that ended long ago: listed (it has a rule), not held.
            await h.server.putEvent(
                eventText("old", title: "Old series", hours: -5 * 365 * 24, rule: "FREQ=DAILY;COUNT=2"), uid: "old", in: work)
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "Review"), uid: "b", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")
            #expect(try h.titles() == ["Planning", "Review"])
            #expect(try h.store.refusedEventCount(calendar.id) == 2)

            // Nothing changed: nothing is fetched.
            let asked = await h.server.multigets.count
            try await syncer.sync()
            #expect(await h.server.multigets.count == asked)

            // One event changed: only it is fetched.
            await h.server.putEvent(eventText("b", title: "Review 2"), uid: "b", in: work)
            try await syncer.sync()
            #expect(await h.server.multigets.last == ["/calendars/c1/b.ics"])
            #expect(try h.store.refusedEventCount(calendar.id) == 2)

            // Mended on the server, it is read and no longer counted.
            await h.server.putEvent(eventText("loud", title: "Two alarms", alarm: "-PT5M"), uid: "loud", in: work)
            try await syncer.sync()
            #expect(try h.titles() == ["Planning", "Review 2", "Two alarms"])
            #expect(try h.store.refusedEventCount(calendar.id) == 1)
        }
    }

    /// An object past the 2 MiB cap: a description of 2.1 MB.
    private func oversized(_ uid: String, title: String) -> String {
        eventText(uid, title: title, extra: ["DESCRIPTION:" + String(repeating: "a", count: 2_100_000)])
    }

    @Test(arguments: [true, false]) func objectPastTheCapIsRefusedAndKept(sync: Bool) async throws {
        try await withCalendars(sync: sync) { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            await h.server.putEvent(oversized("a", title: "Planning, long"), uid: "a", in: work)
            await h.server.putEvent(oversized("b", title: "Big"), uid: "b", in: work)
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")
            // The copy held stays; both are counted.
            #expect(try h.titles() == ["Planning"])
            #expect(try h.store.refusedEventCount(calendar.id) == 2)
            await h.server.putEvent(eventText("c", title: "Retro"), uid: "c", in: work)
            try await syncer.sync()
            #expect(await h.server.multigets.last == ["/calendars/c1/c.ics"])
            #expect(try h.titles() == ["Planning", "Retro"])
        }
    }

    @Test func deleteOfAnObjectPastTheCapIsNotDone() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            try h.store.deleteEvent(held.id, scope: .event)
            await h.server.putEvent(oversized("a", title: "Planning, long"), uid: "a", in: work)
            try await syncer.runChanges()
            #expect(await h.server.events(in: work)["a"] != nil)
            #expect(try h.store.event(held.id, occurrence: nil)?.changeFailed == true)
        }
    }

    @Test func ownerCreateEditDeleteReachServer() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(
                eventText("kept", title: "Planning", extra: ["X-OTHER-APP:keep me"]), uid: "kept", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")

            // Create.
            let start = EventTime.utc(fixedNow.addingTimeInterval(5 * 3_600))
            let made = try h.store.createEvent(
                EventDetails(
                    title: "Lunch", start: start, end: .utc(fixedNow.addingTimeInterval(6 * 3_600)), reminder: 15),
                rule: nil, in: calendar.id)
            try await syncer.runChanges()
            let created = try #require(try await h.serverSeries(work).first { $0.base?.title == "Lunch" })
            #expect(created.uid.hasPrefix("urn:uuid:"))
            #expect(created.base?.reminder == 15)
            #expect(try h.store.series(made)?.uid == created.uid)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)

            // Edit.
            let kept = try h.event(titled: "Planning")
            var details = kept.occurrence.details
            details.title = "Planning, renamed"
            try h.store.updateEvent(kept.id, details, rule: nil, scope: .event)
            try await syncer.runChanges()
            let text = try #require(await h.server.events(in: work)["kept"])
            #expect(text.contains("X-OTHER-APP:keep me"))
            let renamed = try #require(try await h.serverSeries(work).first { $0.uid == "kept" })
            #expect(renamed.base?.title == "Planning, renamed")

            // A second sync takes the server's copy as it is.
            try await syncer.sync()
            #expect(try h.titles() == ["Lunch", "Planning, renamed"])

            // Delete.
            try h.store.deleteEvent(kept.id, scope: .event)
            try h.store.deleteEvent(made, scope: .event)
            try await syncer.runChanges()
            #expect(await h.server.events(in: work).isEmpty)
            #expect(try h.titles().isEmpty)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func retriedCreateKeepsAnotherClientsChange() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")
            let made = try h.store.createEvent(
                EventDetails(title: "Lunch", start: .utc(fixedNow), end: .utc(fixedNow.addingTimeInterval(3_600))),
                rule: nil, in: calendar.id)
            // The create lands, its answer is lost.
            await h.server.dropNextPutAnswer()
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 1)
            // Another client edits it before the retry.
            let (name, text) = try #require(await h.server.events(in: work).first)
            let edited = text.replacingOccurrences(of: "SUMMARY:Lunch", with: "SUMMARY:Lunch at noon\r\nX-OTHER-APP:theirs")
            await h.server.putEvent(edited, uid: name, in: work)

            try await syncer.runChanges()
            let after = try #require(await h.server.events(in: work)[name])
            #expect(after.contains("X-OTHER-APP:theirs"))
            #expect(after.contains("SUMMARY:Lunch at noon"))
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
            #expect(try h.store.event(made, occurrence: nil)?.occurrence.details.title == "Lunch at noon")
        }
    }

    @Test func retriedCreateWritesLaterEditsOverTheServersCopy() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")
            let details = EventDetails(title: "Lunch", start: .utc(fixedNow), end: .utc(fixedNow.addingTimeInterval(3_600)))
            let made = try h.store.createEvent(details, rule: nil, in: calendar.id)
            await h.server.dropNextPutAnswer()
            await #expect(throws: SyncError.self) { try await syncer.runChanges() }
            let (name, text) = try #require(await h.server.events(in: work).first)
            await h.server.putEvent(
                text.replacingOccurrences(of: "SUMMARY:Lunch", with: "SUMMARY:Lunch\r\nX-OTHER-APP:theirs"), uid: name,
                in: work)
            var renamed = details
            renamed.place = "Café"
            try h.store.updateEvent(made, renamed, rule: nil, scope: .event)

            try await syncer.runChanges()
            let after = try #require(await h.server.events(in: work)[name])
            #expect(after.contains("X-OTHER-APP:theirs"))
            #expect(after.contains("LOCATION:Café"))
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    /// A create sent, its answer lost; the server's copy then gets `theirs` as its title, and the
    /// owner edits the event to `ours` before the retry. Returns the server's object after it.
    private func retriedCreate(
        _ h: CalendarHarness, theirs: String, ours: (inout EventDetails) -> Void
    ) async throws -> EventSeries? {
        let work = await h.server.addCalendar("Work")
        let syncer = h.syncer()
        try await syncer.sync()
        let calendar = try h.calendar(named: "Work")
        let details = EventDetails(title: "Lunch", start: .utc(fixedNow), end: .utc(fixedNow.addingTimeInterval(3_600)))
        let made = try h.store.createEvent(details, rule: nil, in: calendar.id)
        await h.server.dropNextPutAnswer()
        await #expect(throws: SyncError.self) { try await syncer.runChanges() }
        let (name, text) = try #require(await h.server.events(in: work).first)
        await h.server.putEvent(text.replacingOccurrences(of: "SUMMARY:Lunch", with: "SUMMARY:" + theirs), uid: name, in: work)
        var edited = details
        ours(&edited)
        try h.store.updateEvent(made, edited, rule: nil, scope: .event)
        try await syncer.runChanges()
        #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        return try await h.serverSeries(work).first
    }

    @Test func retriedCreateKeepsTheirFieldAndOurs() async throws {
        try await withCalendars { h in
            let server = try await retriedCreate(h, theirs: "Lunch at noon") { $0.place = "Café" }
            #expect(server?.base?.title == "Lunch at noon")
            #expect(server?.base?.place == "Café")
        }
    }

    @Test func retriedCreateWithTheSameFieldChangedTakesTheOwners() async throws {
        try await withCalendars { h in
            let server = try await retriedCreate(h, theirs: "Lunch at noon") { $0.title = "Team lunch" }
            #expect(server?.base?.title == "Team lunch")
        }
    }

    @Test func createDeletedBeforeSendingSendsNothing() async throws {
        try await withCalendars { h in
            _ = await h.server.addCalendar("Work")
            let syncer = h.syncer()
            try await syncer.sync()
            let calendar = try h.calendar(named: "Work")
            let made = try h.store.createEvent(
                EventDetails(title: "Never mind", start: .utc(fixedNow), end: .utc(fixedNow.addingTimeInterval(600))),
                rule: nil, in: calendar.id)
            try h.store.deleteEvent(made, scope: .event)
            let before = await h.server.requests.count
            try await syncer.runChanges()
            #expect(await h.server.requests.count == before)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func occurrenceEditReachesServerAsOverride() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(
                eventText("w", title: "Standup", hours: 20, rule: "FREQ=DAILY;COUNT=5"), uid: "w", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let second = try #require(try h.occurrences().filter { $0.occurrence.details.title == "Standup" }.dropFirst().first)
            let recurrence = try #require(second.occurrence.recurrenceID)
            var details = second.occurrence.details
            details.title = "Standup, later"
            details.start = .utc(second.occurrence.start.addingTimeInterval(3_600))
            details.end = .utc(second.occurrence.end.addingTimeInterval(3_600))
            try h.store.updateEvent(second.id, details, rule: nil, scope: .occurrence(recurrence))
            try await syncer.runChanges()
            let series = try #require(try await h.serverSeries(work).first)
            #expect(series.rule?.count == 5)
            let override = try #require(series.overrides.first)
            #expect(override.recurrenceID == recurrence)
            #expect(override.details.title == "Standup, later")
            try await syncer.sync()
            let shown = try h.occurrences().map(\.occurrence.details.title)
            #expect(shown.count == 5)
            #expect(shown.filter { $0 == "Standup, later" }.count == 1)
        }
    }

    @Test func conflictKeepsOwnEditAndServerVersion() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            var mine = held.occurrence.details
            mine.title = "Mine"
            try h.store.updateEvent(held.id, mine, rule: nil, scope: .event)
            await h.server.putEvent(eventText("a", title: "Theirs"), uid: "a", in: work)
            try await syncer.sync()
            let shown = try h.event(titled: "Theirs")
            #expect(shown.id == held.id)
            guard case let .update(kept, _, _) = shown.conflict else {
                Issue.record("no conflict held")
                return
            }
            #expect(kept.title == "Mine")
            #expect(try await h.serverSeries(work).first?.base?.title == "Theirs")
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func editDuringASendThatMeetsAConflictIsHeld() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            var first = held.occurrence.details
            first.place = "Room 1"
            try h.store.updateEvent(held.id, first, rule: nil, scope: .event)
            // Another client renames the event, and the owner edits again while the send is in flight.
            await h.server.putEvent(eventText("a", title: "Theirs"), uid: "a", in: work)
            var second = first
            second.place = "Room 2"
            let store = h.store
            let id = held.id
            let newer = second
            let edited = Mutex(false)
            await h.server.beforeNextPut {
                edited.withLock { $0 = (try? store.updateEvent(id, newer, rule: nil, scope: .event)) != nil }
            }
            try await syncer.runChanges()
            try await syncer.sync()
            #expect(edited.withLock { $0 })
            let server = try #require(try await h.serverSeries(work).first?.base)
            #expect(server.title == "Theirs" && server.place.isEmpty)
            let shown = try h.event(titled: "Theirs")
            #expect(shown.id == held.id)
            guard case let .update(kept, _, _) = shown.conflict else {
                Issue.record("no conflict held")
                return
            }
            #expect(kept.place == "Room 2" && kept.title == "Planning")
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func deleteThatMeetsAConflictIsAFailedChange() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            try h.store.deleteEvent(held.id, scope: .event)
            let serverText = eventText("a", title: "Theirs")
            await h.server.putEvent(serverText, uid: "a", in: work)
            try await syncer.sync()
            #expect(await h.server.events(in: work)["a"] == serverText)
            let shown = try h.event(titled: "Theirs")
            #expect(shown.id == held.id)
            #expect(shown.changeFailed && shown.conflict == nil)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test(arguments: [true, false]) func discardingAFailedChangeFetchesTheServersLatestVersion(
        syncCollection: Bool
    ) async throws {
        try await withCalendars(sync: syncCollection) { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            try h.store.deleteEvent(held.id, scope: .event)
            await h.server.putEvent(eventText("a", title: "Theirs"), uid: "a", in: work)
            try await syncer.sync()
            #expect(try h.store.event(held.id, occurrence: nil)?.changeFailed == true)
            // The server changes it again while the failure waits for the owner.
            await h.server.putEvent(eventText("a", title: "Latest"), uid: "a", in: work)
            try await syncer.sync()
            #expect(try h.titles() == ["Theirs"])

            try EventRestore.discardFailedChange(held.id, in: h.store)
            try await syncer.sync()

            #expect(try h.titles() == ["Latest"])
            // Its ETag is the current one: a delete is taken rather than refused.
            try h.store.deleteEvent(held.id, scope: .event)
            try await syncer.runChanges()
            #expect(await h.server.events(in: work)["a"] == nil)
        }
    }

    /// A Discard drops the calendar's sync token, and the sync after it lists the window again rather
    /// than asking for every change since the start: an object far outside the window is not fetched.
    @Test(arguments: [true, false]) func aDiscardNeverListsTheWholeCalendar(syncCollection: Bool) async throws {
        try await withCalendars(sync: syncCollection) { h in
            let work = await h.server.addCalendar("Work")
            let later = Calendar(identifier: .gregorian).date(byAdding: .year, value: 5, to: fixedNow) ?? fixedNow
            let hours = later.timeIntervalSince(fixedNow) / 3_600
            await h.server.putEvent(eventText("far", title: "Far ahead", hours: hours), uid: "far", in: work)
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            try h.store.deleteEvent(held.id, scope: .event)
            await h.server.putEvent(eventText("a", title: "Theirs"), uid: "a", in: work)
            try await syncer.sync()
            try EventRestore.discardFailedChange(held.id, in: h.store)
            try await syncer.sync()

            #expect(try h.titles() == ["Theirs"])
            let calendar = try h.calendar(named: "Work")
            #expect(try h.store.skippedEvents(calendar.id).keys.allSatisfy { !$0.contains("far") })
        }
    }

    @Test func goneCalendarFailsQueuedChange() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            let syncer = h.syncer()
            try await syncer.sync()
            let held = try h.event(titled: "Planning")
            var mine = held.occurrence.details
            mine.title = "Mine"
            try h.store.updateEvent(held.id, mine, rule: nil, scope: .event)
            await h.server.removeCalendar(work)
            try await syncer.sync()
            #expect(try h.store.event(held.id, occurrence: nil)?.changeFailed == true)
            #expect(try h.store.pendingEventChangeCount(h.account.id) == 0)
        }
    }

    @Test func remindersFollowServerChanges() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning", hours: 2, alarm: "-PT15M"), uid: "a", in: work)
            await h.server.putEvent(eventText("b", title: "No alarm", hours: 3), uid: "b", in: work)
            let reminders = RecordingReminders()
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: FakeDoH(),
                davSession: URLSession(configuration: .ephemeral), probe: { _ in nil }, reminders: reminders)
            await coordinator.refreshAll()
            let first = await reminders.last
            #expect(first.map(\.title) == ["Planning"])
            #expect(first.first?.fire == fixedNow.addingTimeInterval(2 * 3_600 - 900))

            await h.server.putEvent(eventText("a", title: "Planning", hours: 3, alarm: "-PT15M"), uid: "a", in: work)
            await coordinator.refreshAll()
            let moved = await reminders.last
            #expect(moved.map(\.fire) == [fixedNow.addingTimeInterval(3 * 3_600 - 900)])

            await h.server.removeEvent(uid: "a", in: work)
            await coordinator.refreshAll()
            #expect(await reminders.last.isEmpty)
        }
    }

    /// Coming to the front brings the calendars too, and their reminders: an event added elsewhere
    /// shows without a pull to refresh.
    @Test func comingToTheFrontSyncsCalendars() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning", hours: 2, alarm: "-PT15M"), uid: "a", in: work)
            let reminders = RecordingReminders()
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: FakeDoH(),
                davSession: URLSession(configuration: .ephemeral), probe: { _ in nil }, reminders: reminders)
            await coordinator.startForeground()
            let planned = await eventually { await reminders.last.map(\.title) == ["Planning"] }
            await coordinator.stopForeground()
            #expect(planned)
        }
    }

    @Test func phoneZoneChangeLaysEventsOutAgain() async throws {
        try await withCalendars { h in
            try h.store.replaceCalendars([(href: "/cal/", name: "Work", color: nil, isReadOnly: false)], for: h.account.id)
            let calendar = try h.calendar(named: "Work")
            // Laid out on a phone far from here.
            let far = TimeZone(identifier: "Pacific/Kiritimati") ?? .gmt
            let wall = DateComponents(year: 2026, month: 11, day: 7, hour: 9, minute: 0, second: 0)
            let nine = EventDetails(title: "Floating", start: .floating(wall), end: .floating(wall))
            try h.store.upsertRemote(
                href: "/cal/f.ics", etag: "1", ics: Data(), series: EventSeries(uid: "f", base: nine),
                in: calendar.id, window: CalendarWindow.window(now: fixedNow, zone: far), phoneZone: far, scheduleTag: nil)
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets)
            await coordinator.phoneZoneChanged()
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            let start = try #require(try h.occurrences().first?.occurrence.start)
            #expect(local.dateComponents([.hour, .day], from: start) == DateComponents(day: 7, hour: 9))
        }
    }

    @Test func zoneChangeNobodyToldOfLaysEventsOutAgain() async throws {
        try await withCalendars { h in
            try h.store.replaceCalendars([(href: "/cal/", name: "Work", color: nil, isReadOnly: false)], for: h.account.id)
            let calendar = try h.calendar(named: "Work")
            let wall = DateComponents(year: 2026, month: 11, day: 7, hour: 9, minute: 0, second: 0)
            let nine = EventDetails(title: "Floating", start: .floating(wall), end: .floating(wall))
            try h.store.upsertRemote(
                href: "/cal/f.ics", etag: "1", ics: Data(), series: EventSeries(uid: "f", base: nine),
                in: calendar.id, window: CalendarWindow.window(now: fixedNow, zone: stockholm), phoneZone: stockholm, scheduleTag: nil)
            let zone = Mutex(stockholm)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, phoneZone: { zone.withLock { $0 } })
            await coordinator.dayChanged()
            // The phone moves on the same day, and the app is not told.
            let far = TimeZone(identifier: "America/New_York") ?? .gmt
            zone.withLock { $0 = far }
            await coordinator.dayChanged()
            var local = Calendar(identifier: .gregorian)
            local.timeZone = far
            let start = try #require(try h.occurrences().first?.occurrence.start)
            #expect(local.dateComponents([.hour, .day], from: start) == DateComponents(day: 7, hour: 9))
        }
    }

    @Test func newDayLaysEventsOutAgain() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("d", title: "Daily", hours: 1, rule: "FREQ=DAILY"), uid: "d", in: work)
            let clock = h.clock
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { clock.now })
            await coordinator.refreshAll()
            let end = CalendarWindow.window(now: clock.now, zone: .current).upperBound
            let later = end.addingTimeInterval(86_400)
            let before = try h.store.occurrences(from: end, to: later, in: nil)
            #expect(before.isEmpty)
            clock.advance(days: 1)
            await coordinator.refreshAll()
            let after = try h.store.occurrences(from: end, to: later, in: nil)
            #expect(after.count == 1)
        }
    }

    @Test func dayChangeLaysEventsOutWithoutASync() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("d", title: "Daily", hours: 1, rule: "FREQ=DAILY"), uid: "d", in: work)
            let clock = h.clock
            let reminders = RecordingReminders()
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { clock.now }, reminders: reminders)
            await coordinator.refreshAll()
            let requests = await h.server.requests.count
            let planned = await reminders.replaced.count
            let end = CalendarWindow.window(now: clock.now, zone: .current).upperBound
            let later = end.addingTimeInterval(86_400)
            clock.advance(days: 1)
            await coordinator.dayChanged()
            let after = try h.store.occurrences(from: end, to: later, in: nil)
            #expect(after.count == 1)
            #expect(await h.server.requests.count == requests)
            #expect(await reminders.replaced.count == planned + 1)
        }
    }

    @Test func aNewStartOnTheSameDayLeavesTheLayoutAlone() async throws {
        try await withCalendars { h in
            try h.store.replaceCalendars([(href: "/cal/", name: "Work", color: nil, isReadOnly: false)], for: h.account.id)
            let calendar = try h.calendar(named: "Work")
            let clock = h.clock
            let first = offlineCoordinator(store: h.store, secrets: h.secrets, now: { clock.now })
            await first.dayChanged()
            // Kept for one day only (the test clock's): a layout of the whole window gives it hundreds.
            let wall = DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 0, second: 0)
            let daily = EventSeries(
                uid: "d", base: EventDetails(title: "Daily", start: .floating(wall), end: .floating(wall)),
                rule: RecurrenceRule(freq: .daily))
            let today = Calendar.current.startOfDay(for: clock.now)
            try h.store.upsertRemote(
                href: "/cal/d.ics", etag: "1", ics: Data(), series: daily, in: calendar.id,
                window: today...today.addingTimeInterval(86_399), phoneZone: .current, scheduleTag: nil)
            let wide = CalendarWindow.window(now: clock.now, zone: .current)
            #expect(try h.store.occurrences(from: wide.lowerBound, to: wide.upperBound, in: nil).count == 1)

            // The app starts again the same day: nothing is laid out again.
            let second = offlineCoordinator(store: h.store, secrets: h.secrets, now: { clock.now })
            await second.dayChanged()
            #expect(try h.store.occurrences(from: wide.lowerBound, to: wide.upperBound, in: nil).count == 1)

            // The next day it is.
            clock.advance(days: 1)
            await second.dayChanged()
            let moved = CalendarWindow.window(now: clock.now, zone: .current)
            #expect(try h.store.occurrences(from: moved.lowerBound, to: moved.upperBound, in: nil).count > 100)
        }
    }

    @Test func queuedChangeReschedulesReminders() async throws {
        try await withCalendars { h in
            _ = await h.server.addCalendar("Work")
            let reminders = RecordingReminders()
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, actionDelay: .milliseconds(50), reminders: reminders)
            await coordinator.refreshAll()
            #expect(await reminders.last.isEmpty)
            let calendar = try h.calendar(named: "Work")
            let start = fixedNow.addingTimeInterval(7_200)
            _ = try h.store.createEvent(
                EventDetails(title: "Lunch", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)), reminder: 15),
                rule: nil, in: calendar.id)
            #expect(await eventually { await reminders.last.map(\.title) == ["Lunch"] })
            #expect(try await eventually { try h.store.pendingEventChangeCount(h.account.id) == 0 })
        }
    }

    @Test func eventFollowsTheAccountsEmailWithoutASync() async throws {
        try await withCalendars { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(
                eventText("o", title: "Mine later", extra: ["ORGANIZER:mailto:new@example.org"]), uid: "o", in: work)
            try await h.syncer().sync()
            #expect(try h.event(titled: "Mine later").isEditable == false)
            var renamed = h.account
            renamed.email = "new@example.org"
            try h.store.save(renamed)
            #expect(try h.event(titled: "Mine later").isEditable)
        }
    }

    @Test func aStalePlanFinishingLastDoesNotWin() async throws {
        try await withCalendars { h in
            try h.store.replaceCalendars([(href: "/cal/", name: "Work", color: nil, isReadOnly: false)], for: h.account.id)
            let calendar = try h.calendar(named: "Work")
            let start = fixedNow.addingTimeInterval(7_200)
            let lunch = EventDetails(
                title: "Lunch", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)), reminder: 15)
            try h.store.upsertRemote(
                href: "/cal/l.ics", etag: "1", ics: Data(), series: EventSeries(uid: "l", base: lunch),
                in: calendar.id, window: CalendarWindow.window(now: fixedNow, zone: stockholm), phoneZone: stockholm, scheduleTag: nil)
            let reminders = GatedReminders()
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, reminders: reminders)
            let first = Task { await coordinator.rescheduleReminders() }
            #expect(await eventually { await reminders.waiting })
            try h.store.removeRemote(hrefs: ["/cal/l.ics"], in: calendar.id)
            let second = Task { await coordinator.rescheduleReminders() }
            try? await Task.sleep(for: .milliseconds(100))
            await reminders.release()
            await first.value
            await second.value
            #expect(await reminders.last.isEmpty, "the removed event's reminder is not put back")
        }
    }

    @Test func anOfflineEditMovesItsReminderBeforeItIsSent() async throws {
        let gate = Mutex(false)
        let asked = Mutex(0)
        let held = FakeHTTPServer { _ in
            asked.withLock { $0 += 1 }
            while !gate.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            return FakeHTTPResponse(status: 503)
        }
        let port = try await held.start()
        defer { held.stop() }
        try await withCalendars { h in
            var account = h.account
            account.calDAV = "http://127.0.0.1:\(port)/"
            try h.store.save(account)
            try h.store.replaceCalendars(
                [(href: "http://127.0.0.1:\(port)/cal/", name: "Work", color: nil, isReadOnly: false)], for: h.account.id)
            let calendar = try h.calendar(named: "Work")
            let reminders = RecordingReminders()
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, actionDelay: .milliseconds(50), reminders: reminders)
            let start = fixedNow.addingTimeInterval(7_200)
            _ = try h.store.createEvent(
                EventDetails(title: "Lunch", start: .utc(start), end: .utc(start.addingTimeInterval(3_600)), reminder: 15),
                rule: nil, in: calendar.id)
            // While the server holds the send, the reminder is on the phone already.
            let inFlight = await eventually { asked.withLock { $0 } > 0 }
            let moved = await reminders.last.map(\.title) == ["Lunch"]
            gate.withLock { $0 = true }
            #expect(inFlight)
            #expect(moved)
            _ = coordinator
        }
    }

    @Test func accountWithoutCalDAVSyncsNothing() async throws {
        try await withCalendars(calDAV: false) { h in
            let work = await h.server.addCalendar("Work")
            await h.server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
            try await h.syncer().sync()
            try await h.syncer().runChanges()
            #expect(await h.server.requests.isEmpty)
            #expect(try h.store.calendars(h.account.id).isEmpty)
        }
    }
}
