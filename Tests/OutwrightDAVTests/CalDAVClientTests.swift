// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightDAV

@Suite struct CalDAVClientTests {
    let session = URLSession(configuration: .ephemeral)

    private func start(sync: Bool = true) async throws -> (FakeCalDAVServer, URL) {
        let server = FakeCalDAVServer(offersSyncCollection: sync)
        let port = try await server.start()
        return (server, try #require(URL(string: "http://127.0.0.1:\(port)/")))
    }

    private func client(_ context: URL, password: String = "secret") -> CalDAVClient {
        CalDAVClient(
            context: context, credentials: DAVCredentials(user: "jk@example.org", password: password),
            trustedHosts: ["127.0.0.1"], session: session)
    }

    private static func event(_ uid: String, start: String = "20260315T100000Z", rule: String? = nil) -> String {
        let recurrence = rule.map { "RRULE:\($0)\r\n" } ?? ""
        return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example.org//EN\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\n"
            + "DTSTAMP:20260101T000000Z\r\nDTSTART:\(start)\r\n\(recurrence)SUMMARY:\(uid)\r\nEND:VEVENT\r\n"
            + "END:VCALENDAR\r\n"
    }

    private static func date(_ year: Int) -> Date {
        Date(timeIntervalSince1970: Double(year - 1970) * 365.25 * 86_400)
    }

    @Test func findsCalendarsAndSkipsNothingSilently() async throws {
        let (server, context) = try await start()
        _ = await server.addCalendar("Work", color: "#D04A2FFF")
        _ = await server.addCalendar("Tasks", components: ["VTODO"])
        _ = await server.addCalendar("Shared", readOnly: true)
        let calendars = try await client(context).calendars()
        await server.stop()
        #expect(calendars.map(\.name).sorted() == ["Shared", "Tasks", "Work"])
        let work = try #require(calendars.first { $0.name == "Work" })
        #expect(work.color == "#D04A2F")
        #expect(work.holdsEvents && !work.isReadOnly && work.offersSyncCollection)
        #expect(work.ctag != nil && work.syncToken != nil)
        #expect(calendars.first { $0.name == "Tasks" }?.holdsEvents == false)
        #expect(calendars.first { $0.name == "Shared" }?.isReadOnly == true)
        #expect(calendars.first { $0.name == "Shared" }?.holdsEvents == true)
    }

    @Test func schedulingIsWhatTheServerSays() async throws {
        let (server, context) = try await start()
        _ = await server.addCalendar("Work")
        let schedules = try await client(context).schedules()
        // RFC 6638 › 2: no `calendar-auto-schedule` in the DAV header, no scheduling.
        await server.stopAutoScheduling()
        let plain = try await client(context).schedules()
        await server.stop()
        #expect(schedules)
        #expect(!plain)
    }

    @Test func timeRangeListsOnlyTheWindow() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        await server.putEvent(Self.event("old", start: "20200301T100000Z"), uid: "old", in: calendar)
        await server.putEvent(Self.event("now", start: "20260315T100000Z"), uid: "now", in: calendar)
        await server.putEvent(
            Self.event("series", start: "20190101T090000Z", rule: "FREQ=WEEKLY"), uid: "series", in: calendar)
        let etags = try await client(context).etags(calendar, from: Self.date(2026), to: Self.date(2027))
        await server.stop()
        #expect(Set(etags.keys.map(\.lastPathComponent)) == ["now.ics", "series.ics"])
    }

    @Test func syncCollectionReportsChangesAndRemovals() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        for uid in ["a", "b", "c"] { await server.putEvent(Self.event(uid), uid: uid, in: calendar) }
        let dav = client(context)
        let first = try await dav.changes(calendar, since: nil)
        #expect(Set(first.changed.map(\.href.lastPathComponent)) == ["a.ics", "b.ics", "c.ics"])
        let token = try #require(first.token)
        await server.putEvent(Self.event("b", start: "20260316T100000Z"), uid: "b", in: calendar)
        await server.removeEvent(uid: "c", in: calendar)
        let second = try await dav.changes(calendar, since: token)
        await server.stop()
        #expect(second.changed.map(\.href.lastPathComponent) == ["b.ics"])
        #expect(second.removed.map(\.lastPathComponent) == ["c.ics"])
        #expect(second.token != nil && second.token != token)
    }

    @Test func forgottenTokenIsReported() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        await server.putEvent(Self.event("a"), uid: "a", in: calendar)
        let dav = client(context)
        let token = try #require(try await dav.changes(calendar, since: nil).token)
        await server.forgetSyncTokens()
        await #expect(throws: DAVError.tokenInvalid) { try await dav.changes(calendar, since: token) }
        await server.stop()
    }

    @Test func multigetReadsInBatches() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        for index in 0..<250 { await server.putEvent(Self.event("u\(index)"), uid: "u\(index)", in: calendar) }
        let dav = client(context)
        let etags = try await dav.etags(calendar, from: Self.date(2026), to: Self.date(2027))
        #expect(etags.count == 250)
        let found = try await dav.resources(calendar, hrefs: Array(etags.keys))
        let reports = await server.requests.filter { $0.method == "REPORT" }.count
        await server.stop()
        #expect(found.count == 250)
        #expect(reports == 4)
        for resource in found {
            #expect(etags[resource.href] == resource.etag)
            let uid = resource.href.deletingPathExtension().lastPathComponent
            #expect(String(decoding: resource.data, as: UTF8.self).contains("UID:\(uid)\r\n"))
        }
    }

    @Test func putAndDeleteUsePreconditions() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        let dav = client(context)
        let href = calendar.appending(path: "new.ics")
        let created = try await dav.put(Data(Self.event("new").utf8), at: href, ifMatch: nil)
        let etag = try #require(created.etag)
        await #expect(throws: DAVError.preconditionFailed) {
            try await dav.put(Data(Self.event("new", start: "20260401T100000Z").utf8), at: href, ifMatch: "\"stale\"")
        }
        #expect(await server.events(in: calendar)["new"] == Self.event("new"))
        await #expect(throws: DAVError.preconditionFailed) { try await dav.delete(href, ifMatch: "\"stale\"") }
        #expect(await server.events(in: calendar)["new"] != nil)
        let updated = try await dav.put(
            Data(Self.event("new", start: "20260402T100000Z").utf8), at: href, ifMatch: etag).etag
        #expect(updated != nil && updated != etag)
        try await dav.delete(href, ifMatch: try #require(updated))
        #expect(await server.events(in: calendar)["new"] == nil)
        try await dav.delete(href, ifMatch: etag)
        await server.stop()
    }

    /// RFC 6638 › 3.2.2.1: a server may refuse an attendee's change to what the organiser controls;
    /// the refusal is told apart from a stale ETag, and the owner's answer is still taken.
    @Test func aForbiddenAttendeeChangeIsToldApart() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        let invited = { (start: String, partstat: String) in
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example.org//EN\r\nBEGIN:VEVENT\r\nUID:inv\r\n"
                + "DTSTAMP:20260101T000000Z\r\nDTSTART:\(start)\r\nSUMMARY:Review\r\n"
                + "ORGANIZER:mailto:boss@example.org\r\n"
                + "ATTENDEE;PARTSTAT=\(partstat):mailto:jk@example.org\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        }
        await server.putEvent(invited("20260315T100000Z", "NEEDS-ACTION"), uid: "inv", in: calendar)
        await server.refuseAttendeeChanges()
        let dav = client(context)
        let href = calendar.appending(path: "inv.ics")
        let etag = try #require(try await dav.fetch(calendar, hrefs: [href]).found.first?.etag)
        await #expect(throws: DAVError.attendeeChangeRefused) {
            try await dav.put(Data(invited("20260316T100000Z", "NEEDS-ACTION").utf8), at: href, ifMatch: etag)
        }
        _ = try await dav.put(Data(invited("20260315T100000Z", "ACCEPTED").utf8), at: href, ifMatch: etag)
        #expect(await server.events(in: calendar)["inv"] == invited("20260315T100000Z", "ACCEPTED"))
        await server.stop()
    }

    /// RFC 6638: an object the server schedules comes with its `Schedule-Tag`, from a multiget and
    /// in the answer to a write; one it does not schedule has none.
    @Test func scheduleTagComesWithReadsAndWrites() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        await server.putEvent(Self.event("plain"), uid: "plain", in: calendar)
        await server.putEvent(Self.event("kept"), uid: "kept", in: calendar)
        await server.markScheduled(uid: "kept", in: calendar)
        let dav = client(context)
        let (plain, kept) = (calendar.appending(path: "plain.ics"), calendar.appending(path: "kept.ics"))
        let found = try await dav.fetch(calendar, hrefs: [plain, kept]).found
        let keptCopy = try #require(found.first { $0.href.lastPathComponent == "kept.ics" })
        let plainCopy = try #require(found.first { $0.href.lastPathComponent == "plain.ics" })
        let tag = try #require(keptCopy.scheduleTag)
        #expect(plainCopy.scheduleTag == nil)
        let rewritten = try await dav.put(
            Data(Self.event("kept", start: "20260316T100000Z").utf8), at: kept, ifMatch: keptCopy.etag)
        #expect(rewritten.scheduleTag == tag)
        #expect(rewritten.etag != nil)
        let plainWritten = try await dav.put(
            Data(Self.event("plain", start: "20260316T100000Z").utf8), at: plain, ifMatch: plainCopy.etag)
        #expect(plainWritten.scheduleTag == nil)
        await server.stop()
    }

    @Test func eventsAreFoundByUID() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        await server.putEvent(Self.event("a&b@example.org"), uid: "first", in: calendar)
        await server.putEvent(Self.event("other@example.org"), uid: "second", in: calendar)
        await server.markScheduled(uid: "first", in: calendar)
        let found = try await client(context).events(withUID: "a&b@example.org", in: calendar)
        let none = try await client(context).events(withUID: "missing@example.org", in: calendar)
        await server.stop()
        #expect(found.map(\.href.lastPathComponent) == ["first.ics"])
        #expect(found.first?.scheduleTag != nil)
        #expect(none.isEmpty)
    }

    @Test func offDomainRedirectSendsNoPassword() async throws {
        let (server, context) = try await start()
        await server.redirectWellKnown(to: "/hop/")
        await server.redirect("/hop/", to: "https://other.example.net/dav/")
        let dav = client(context.appending(path: ".well-known/caldav"))
        await #expect(throws: DAVError.offDomainRedirect(host: "other.example.net")) { try await dav.calendars() }
        let requests = await server.requests
        await server.stop()
        #expect(requests.map(\.path) == ["/.well-known/caldav", "/hop/"])
        let expected = "Basic " + Data("jk@example.org:secret".utf8).base64EncodedString()
        #expect(requests.allSatisfy { $0.authorization == expected })
    }

    @Test func zonedEventOutsideTheWindowIsNotListed() async throws {
        let (server, context) = try await start()
        let calendar = await server.addCalendar("Work")
        let zoned = """
            BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example.org//EN\r\nBEGIN:VTIMEZONE\r\n\
            TZID:Europe/Stockholm\r\nBEGIN:STANDARD\r\nDTSTART:20261025T030000\r\n\
            RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\n\
            END:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:zoned\r\nDTSTAMP:20200101T000000Z\r\n\
            DTSTART;TZID=Europe/Stockholm:20200301T100000\r\nSUMMARY:zoned\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n
            """
        await server.putEvent(zoned, uid: "zoned", in: calendar)
        let etags = try await client(context).etags(calendar, from: Self.date(2026), to: Self.date(2027))
        await server.stop()
        #expect(etags.isEmpty)
    }

    @Test func colourNeedsAsciiHexDigits() {
        #expect(CalDAVClient.color("#d04a2f") == "#D04A2F")
        #expect(CalDAVClient.color("#D04A2FFF") == "#D04A2F")
        #expect(CalDAVClient.color("#０１２３４５") == nil)
        #expect(CalDAVClient.color("D04A2F") == nil)
    }

    @Test func colourIsNilOrSevenAsciiCharacters() {
        var rng = SeededGenerator(state: 7)
        let alphabet: [String] = Array("#0123456789abcdefABCDEFgG \n０１２３ＡＢＣ٣é").map(String.init) + ["\u{0301}", "\r\n"]
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...10, using: &rng)
            let text = (0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }.joined()
            guard let colour = CalDAVClient.color(text) else { continue }
            #expect(colour.utf8.count == 7 && colour.hasPrefix("#"))
            #expect(colour.dropFirst().allSatisfy { $0.isASCII && "0123456789ABCDEF".contains($0) })
        }
    }
}
