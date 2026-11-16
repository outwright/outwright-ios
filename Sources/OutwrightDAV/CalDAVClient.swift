// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A calendar collection on the server.
public struct RemoteCalendar: Sendable, Equatable {
    public let href: URL
    public let name: String
    /// `#RRGGBB`: the server's `calendar-color` with any alpha dropped.
    public let color: String?
    /// The CalendarServer `getctag`: changes whenever anything in the calendar changes.
    public let ctag: String?
    public let syncToken: String?
    public let offersSyncCollection: Bool
    public let isReadOnly: Bool
    /// VEVENT is in the supported component set, or the server names no set.
    public let holdsEvents: Bool
}

/// CalDAV (RFC 4791) against one account's server: discovery, calendar-query for a window,
/// sync-collection (RFC 6578), multiget, and writes with preconditions. Credentials go only to
/// `trustedHosts`.
public actor CalDAVClient {
    private let context: URL
    private let resources: DAVResources

    public init(context: URL, credentials: DAVCredentials, trustedHosts: Set<String>, session: URLSession = .shared) {
        self.context = context
        resources = DAVResources(
            http: HTTPClient(credentials: credentials, trustedHosts: trustedHosts, session: session))
    }

    /// Every calendar: current-user-principal, then calendar-home-set, then the home's members.
    public func calendars() async throws(DAVError) -> [RemoteCalendar] {
        let home = try await resources.home(context, homeSet: .calDAV("calendar-home-set"), prefix: "cal")
        let props = """
            <d:resourcetype/><d:displayname/><ic:calendar-color/><cs:getctag/><d:sync-token/>\
            <d:supported-report-set/><cal:supported-calendar-component-set/><d:current-user-privilege-set/>
            """
        let (members, base) = try await resources.propfind(home, depth: 1, props)
        var found: [RemoteCalendar] = []
        for response in members.responses where found.count < DAVLimits.calendarsPerAccount {
            if let calendar = Self.calendar(response, base) {
                found.append(calendar)
            }
        }
        return found
    }

    /// The server schedules for this account (RFC 6638 › 2): `calendar-auto-schedule` in the DAV
    /// header of OPTIONS on the calendar home. Then it sends the owner's answers to invitations itself.
    public func schedules() async throws(DAVError) -> Bool {
        let home = try await resources.home(context, homeSet: .calDAV("calendar-home-set"), prefix: "cal")
        return try await resources.davClasses(home).contains("calendar-auto-schedule")
    }

    /// The ETags of the events that fall in `from..<to` (and of recurring series that may), by
    /// calendar-query on VEVENT.
    public func etags(_ calendar: URL, from: Date, to: Date) async throws(DAVError) -> [URL: String] {
        let body = """
            <?xml version="1.0" encoding="utf-8"?><cal:calendar-query xmlns:d="DAV:" \
            xmlns:cal="\(DAVNamespace.calDAV)"><d:prop><d:getetag/></d:prop><cal:filter>\
            <cal:comp-filter name="VCALENDAR"><cal:comp-filter name="VEVENT">\
            <cal:time-range start="\(Self.utc(from))" end="\(Self.utc(to))"/></cal:comp-filter>\
            </cal:comp-filter></cal:filter></cal:calendar-query>
            """
        let reply = try await resources.http.send(
            "REPORT", calendar, headers: DAVResources.xmlHeaders(depth: 1), body: Data(body.utf8))
        let status = try DAVResources.multistatus(reply)
        return DAVResources.etags(status, reply.url, calendar, limit: DAVLimits.resourcesPerCalendar)
    }

    /// Changes since `token` (nil: everything) by REPORT sync-collection, sync-level 1. A
    /// truncated answer (507 on the collection) is followed with its token until complete. A
    /// changed member the server gave no ETag for comes with an empty `etag`.
    public func changes(_ calendar: URL, since token: String?) async throws(DAVError) -> CollectionChanges {
        try await resources.changes(calendar, since: token, limit: DAVLimits.resourcesPerCalendar)
    }

    /// The events at `hrefs`, by calendar-multiget in batches of 100. Events the server does not
    /// have, or past the iCalendar size cap, are left out.
    public func resources(_ calendar: URL, hrefs: [URL]) async throws(DAVError) -> [RemoteResource] {
        try await fetch(calendar, hrefs: hrefs).found
    }

    /// The events at `hrefs` with their `Schedule-Tag` where the server schedules them, and those
    /// left out because they are past the iCalendar size cap (an event the server does not have is
    /// in neither).
    public func fetch(_ calendar: URL, hrefs: [URL]) async throws(DAVError) -> FetchedResources {
        let kind = DAVResources.Multiget(
            root: .calDAV("calendar-multiget"), data: .calDAV("calendar-data"),
            maxBytes: DAVLimits.iCalendarBytes, prefix: "cal", scheduleTag: .calDAV("schedule-tag"))
        return try await resources.multiget(calendar, hrefs: hrefs, kind, limit: DAVLimits.resourcesPerCalendar)
    }

    /// The events in `calendar` whose UID is `uid` (calendar-query with a UID prop-filter, RFC 4791
    /// › 9.7.5), read by multiget with their `Schedule-Tag`. Those past the size cap are left out.
    public func events(withUID uid: String, in calendar: URL) async throws(DAVError) -> [RemoteResource] {
        let body = """
            <?xml version="1.0" encoding="utf-8"?><cal:calendar-query xmlns:d="DAV:" \
            xmlns:cal="\(DAVNamespace.calDAV)"><d:prop><d:getetag/></d:prop><cal:filter>\
            <cal:comp-filter name="VCALENDAR"><cal:comp-filter name="VEVENT"><cal:prop-filter name="UID">\
            <cal:text-match collation="i;octet">\(DAVResources.escape(uid))</cal:text-match></cal:prop-filter>\
            </cal:comp-filter></cal:comp-filter></cal:filter></cal:calendar-query>
            """
        let reply = try await resources.http.send(
            "REPORT", calendar, headers: DAVResources.xmlHeaders(depth: 1), body: Data(body.utf8))
        let status = try DAVResources.multistatus(reply)
        let hrefs = DAVResources.etags(status, reply.url, calendar, limit: DAVLimits.resourcesPerCalendar).keys
        guard !hrefs.isEmpty else { return [] }
        return try await fetch(calendar, hrefs: Array(hrefs)).found
    }

    /// Writes an event. A nil `ifMatch` creates it (`If-None-Match: *`). Returns the new ETag and
    /// the `Schedule-Tag` (RFC 6638: the server schedules the object) when the server gives them.
    public func put(_ data: Data, at href: URL, ifMatch etag: String?) async throws(DAVError) -> PutAnswer {
        try await resources.put(data, at: href, ifMatch: etag, contentType: "text/calendar; charset=utf-8")
    }

    /// Deletes an event if it still has `etag`. An event already gone counts as deleted. With
    /// `scheduleReply` false the request carries `Schedule-Reply: F` (RFC 6638 › 8.1): the server
    /// sends the organiser nothing for it (no DECLINED for an attendee's copy).
    public func delete(_ href: URL, ifMatch etag: String, scheduleReply: Bool = true) async throws(DAVError) {
        try await resources.delete(href, ifMatch: etag, headers: scheduleReply ? [:] : ["Schedule-Reply": "F"])
    }

    // MARK: - Reading answers

    private static func calendar(_ response: Multistatus.Response, _ base: URL) -> RemoteCalendar? {
        guard let types = response.property(.dav("resourcetype")),
            types.descendants.contains(.calDAV("calendar")),
            let href = DAVResources.resolve(response.href, base), DAVResources.sameOrigin(href, base)
        else {
            return nil
        }
        let reports = response.property(.dav("supported-report-set"))?.descendants ?? []
        let name = response.property(.dav("displayname")).flatMap { DAVResources.nonEmpty($0.text) }
        let components = response.property(.calDAV("supported-calendar-component-set"))?.nameAttributes
        let color = response.property(QName(namespace: DAVNamespace.appleICal, name: "calendar-color"))
        return RemoteCalendar(
            href: href,
            name: name ?? (href.lastPathComponent.removingPercentEncoding ?? href.lastPathComponent),
            color: color.flatMap { Self.color($0.text) },
            ctag: response.property(QName(namespace: DAVNamespace.calendarServer, name: "getctag"))
                .flatMap { DAVResources.nonEmpty($0.text) },
            syncToken: response.property(.dav("sync-token")).flatMap { DAVResources.nonEmpty($0.text) },
            offersSyncCollection: reports.contains(.dav("sync-collection")),
            isReadOnly: DAVResources.isReadOnly(response.property(.dav("current-user-privilege-set"))),
            holdsEvents: components.map { $0.contains { $0.uppercased() == "VEVENT" } } ?? true)
    }

    /// `#RRGGBB` from `#RRGGBB` or `#RRGGBBAA`; anything else is no colour.
    static func color(_ text: String) -> String? {
        let digits = Array(text.unicodeScalars.dropFirst())
        let hex = Set("0123456789abcdefABCDEF".unicodeScalars)
        guard text.hasPrefix("#"), digits.count == 6 || digits.count == 8, digits.allSatisfy(hex.contains) else {
            return nil
        }
        return "#" + String(String.UnicodeScalarView(digits.prefix(6))).uppercased()
    }

    /// `yyyyMMddTHHmmssZ` in UTC, as CalDAV time ranges are written.
    static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
