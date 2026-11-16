// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// PROPFIND and REPORT for the fake CalDAV server, answered as multistatus XML.
extension FakeCalDAVServer {
    func propfind(_ request: FakeHTTPRequest) -> Data {
        let deep = request.headers["depth"] != "0"
        var responses: [String] = []
        switch locate(request.path) {
        case .principal:
            responses = [principalResponse(request.path)]
        case .home:
            responses = [Self.response(Self.home, "<d:resourcetype><d:collection/></d:resourcetype>")]
            if deep {
                responses += calendars.keys.sorted().map(calendarResponse)
            }
        case let .calendar(path):
            responses = [calendarResponse(path)]
            if deep, let calendar = calendars[path] {
                responses += calendar.events.keys.sorted().compactMap { eventResponse(path, $0, withData: false) }
            }
        case let .event(path, uid):
            guard let response = eventResponse(path, uid, withData: false) else {
                return FakeHTTP.response(404)
            }
            responses = [response]
        case .none:
            return FakeHTTP.response(404)
        }
        return Self.multistatus(responses)
    }

    func report(_ request: FakeHTTPRequest) -> Data {
        guard case let .calendar(path) = locate(request.path), let calendar = calendars[path] else {
            return FakeHTTP.response(404)
        }
        let body = fakeText(request.body)
        if body.contains("sync-collection") {
            return syncCollection(path, calendar, body)
        }
        if body.contains("calendar-query"), let uid = Self.wantedUID(body) {
            if refuseUIDLookup {
                refuseUIDLookup = false
                return FakeHTTP.response(500)
            }
            let matching = calendar.events.keys.sorted().filter { Self.uid(of: calendar.events[$0]?.ics) == uid }
            return Self.multistatus(matching.compactMap { eventResponse(path, $0, withData: false) })
        }
        if body.contains("calendar-query") {
            let window = Self.window(body)
            let matching = calendar.events.keys.sorted().filter { Self.matches(calendar.events[$0]?.ics, window) }
            return Self.multistatus(matching.compactMap { eventResponse(path, $0, withData: false) })
        }
        guard body.contains("calendar-multiget") else {
            return FakeHTTP.response(403)
        }
        let hrefs = body.matches(of: /<(?:\w+:)?href>([^<]*)<\//).map { String($0.output.1) }
        multigets.append(hrefs)
        let responses = hrefs.map { href in
            guard case let .event(eventCalendar, uid) = locate(href), eventCalendar == path,
                let response = eventResponse(path, uid, withData: true)
            else {
                return "<d:response><d:href>\(href)</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
            }
            return response
        }
        return Self.multistatus(responses)
    }

    private func syncCollection(_ path: String, _ calendar: Calendar, _ body: String) -> Data {
        guard offersSyncCollection else {
            return FakeHTTP.xml(403, "<d:error xmlns:d=\"DAV:\"><d:supported-report/></d:error>")
        }
        let token = body.firstMatch(of: /<(?:\w+:)?sync-token>([^<]*)<\//).map { String($0.output.1) } ?? ""
        var since = 0
        if !token.isEmpty {
            guard let issued = revision(of: token) else {
                return FakeHTTP.xml(403, "<d:error xmlns:d=\"DAV:\"><d:valid-sync-token/></d:error>")
            }
            since = issued
        }
        var members: [(revision: Int, xml: String)] = calendar.events.filter { $0.value.modified > since }
            .compactMap { uid, event in eventResponse(path, uid, withData: false).map { (event.modified, $0) } }
        if !token.isEmpty {
            members += calendar.removed.filter { $0.value > since }.map { uid, removed in
                (removed, "<d:response><d:href>\(Self.eventPath(path, uid))</d:href>"
                    + "<d:status>HTTP/1.1 404 Not Found</d:status></d:response>")
            }
        }
        members.sort { $0.revision < $1.revision }
        return Self.multistatus(members.map(\.xml), syncToken: syncToken)
    }

    // MARK: - UID

    /// The text a calendar-query's `prop-filter` on UID asks for (`text-match`), unescaped; nil for a
    /// query without one.
    private static func wantedUID(_ body: String) -> String? {
        guard body.contains("name=\"UID\""),
            let match = body.firstMatch(of: /<(?:\w+:)?text-match[^>]*>([^<]*)<\//)
        else { return nil }
        return String(match.output.1).replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The UID of the object's first VEVENT.
    static func uid(of ics: String?) -> String? {
        ics?.components(separatedBy: "\r\n").first { $0.hasPrefix("UID:") }.map { String($0.dropFirst(4)) }
    }

    // MARK: - Time range

    /// The `start` and `end` of the request's time-range, as `yyyyMMddTHHmmssZ` text.
    private static func window(_ body: String) -> (start: String, end: String) {
        let start = body.firstMatch(of: /start="(\d{8}T\d{6}Z)"/).map { String($0.output.1) } ?? "00000000T000000Z"
        let end = body.firstMatch(of: /end="(\d{8}T\d{6}Z)"/).map { String($0.output.1) } ?? "99999999T235959Z"
        return (start, end)
    }

    /// A resource matches when it has an RRULE or a DTSTART (read as UTC) inside the window.
    private static func matches(_ ics: String?, _ window: (start: String, end: String)) -> Bool {
        guard let ics else {
            return false
        }
        // Only the VEVENT parts count: a VTIMEZONE has DTSTART and RRULE lines of its own.
        var inside = false
        let lines = ics.components(separatedBy: .newlines).filter { line in
            if line == "BEGIN:VEVENT" || line == "END:VEVENT" {
                inside = line.hasPrefix("BEGIN")
                return false
            }
            return inside
        }
        if lines.contains(where: { $0.hasPrefix("RRULE") }) {
            return true
        }
        return lines.contains { line in
            guard line.hasPrefix("DTSTART"), let colon = line.lastIndex(of: ":") else {
                return false
            }
            var digits = line[line.index(after: colon)...].filter { $0.isNumber || $0 == "T" }
            if digits.count == 8 {
                digits += "T000000"
            }
            let value = digits + "Z"
            return value >= window.start && value < window.end
        }
    }

    // MARK: - Answers

    private func principalResponse(_ path: String) -> String {
        Self.response(
            path,
            "<d:current-user-principal><d:href>\(Self.principal)</d:href></d:current-user-principal>"
                + "<cal:calendar-home-set><d:href>\(Self.home)</d:href></cal:calendar-home-set>"
                + "<d:resourcetype><d:collection/><d:principal/></d:resourcetype>")
    }

    private func calendarResponse(_ path: String) -> String {
        guard let calendar = calendars[path] else {
            return ""
        }
        var props = "<d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>"
            + "<d:displayname>\(FakeHTTP.escape(calendar.name))</d:displayname>"
            + "<cs:getctag>\"\(calendar.ctag)\"</cs:getctag>"
        props += calendar.color.map { "<ic:calendar-color>\(FakeHTTP.escape($0))</ic:calendar-color>" } ?? ""
        var reports = "<d:supported-report><d:report><cal:calendar-multiget/></d:report></d:supported-report>"
            + "<d:supported-report><d:report><cal:calendar-query/></d:report></d:supported-report>"
        if offersSyncCollection {
            props += "<d:sync-token>\(syncToken)</d:sync-token>"
            reports += "<d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report>"
        }
        props += "<d:supported-report-set>\(reports)</d:supported-report-set>"
        props += "<cal:supported-calendar-component-set>"
            + calendar.components.map { "<cal:comp name=\"\($0)\"/>" }.joined()
            + "</cal:supported-calendar-component-set>"
        let privileges = calendar.readOnly ? ["read"] : ["read", "write", "write-content", "bind", "unbind"]
        props += "<d:current-user-privilege-set>"
            + privileges.map { "<d:privilege><d:\($0)/></d:privilege>" }.joined()
            + "</d:current-user-privilege-set>"
        return Self.response(path, props)
    }

    private func eventResponse(_ path: String, _ uid: String, withData: Bool) -> String? {
        guard let event = calendars[path]?.events[uid] else {
            return nil
        }
        var props = "<d:getetag>\(FakeHTTP.escape(event.etag))</d:getetag>"
            + "<d:getcontenttype>text/calendar</d:getcontenttype><d:resourcetype/>"
        if withData {
            props += "<cal:calendar-data>\(FakeHTTP.escape(event.ics))</cal:calendar-data>"
            props += event.scheduleTag.map { "<cal:schedule-tag>\(FakeHTTP.escape($0))</cal:schedule-tag>" } ?? ""
        }
        return Self.response(Self.eventPath(path, uid), props)
    }

    private static func response(_ href: String, _ props: String) -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private static func multistatus(_ responses: [String], syncToken: String? = nil) -> Data {
        let token = syncToken.map { "<d:sync-token>\($0)</d:sync-token>" } ?? ""
        return FakeHTTP.xml(
            207,
            "<d:multistatus xmlns:d=\"DAV:\" xmlns:cal=\"urn:ietf:params:xml:ns:caldav\" "
                + "xmlns:cs=\"http://calendarserver.org/ns/\" xmlns:ic=\"http://apple.com/ns/ical/\">"
                + "\(responses.joined())\(token)</d:multistatus>")
    }
}
