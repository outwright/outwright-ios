// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// An in-process CalDAV server on 127.0.0.1 for tests: plain HTTP/1.1, Basic auth for one
/// account, a principal at `/principals/jk/`, calendars under `/calendars/`, events at
/// `<calendar><uid>.ics`. ETags and sync tokens are a counter. `/.well-known/caldav` redirects
/// to the principal (or where `redirectWellKnown` says) without asking for credentials.
public actor FakeCalDAVServer: FakeDAVHost {
    struct Event {
        var ics: String
        var etag: String
        var modified: Int
        /// Set for an object the server's own scheduling keeps (RFC 6638): answered with a
        /// `Schedule-Tag`, and the owner's answer written to it goes to the organiser from here.
        var scheduleTag: String?
    }

    struct Calendar {
        let name: String
        let color: String?
        let components: [String]
        var readOnly: Bool
        var events: [String: Event] = [:]
        var removed: [String: Int] = [:]
        var ctag = 0
    }

    enum Location {
        case principal, home, calendar(String), event(calendar: String, uid: String), none
    }

    static let principal = FakeDAVCore.principal
    static let home = "/calendars/"

    var core: FakeDAVCore
    let offersSyncCollection: Bool
    var calendars: [String: Calendar] = [:]
    var calendarCount = 0
    /// The hrefs of every calendar-multiget asked, one list per request.
    public internal(set) var multigets: [[String]] = []
    var dropPutAnswer = false
    var dropDeleteAnswer = false
    /// The server schedules (RFC 6638 › 2): it says `calendar-auto-schedule` and sends the attendee's
    /// replies itself.
    var autoSchedules = true
    /// The next create is stored and then changed, as a server may change an object as it stores it:
    /// the PUT is answered with the ETag of what was sent, not of what is held.
    var changeNextCreate = false
    /// PUT answers leave out `Schedule-Tag`, as a server may (RFC 6638 › 3.2.10 asks for it only on
    /// some writes): the tag is then known only from a read.
    var putsWithoutScheduleTag = false
    /// An attendee's PUT that changes what the organiser controls is refused (RFC 6638 › 3.2.2.1).
    var refusesAttendeeChanges = false
    /// The next calendar-query on a UID is answered 500.
    var refuseUIDLookup = false
    var scheduleCount = 0
    /// The iMIP REPLYs this server sent itself: one per PUT that changed the owner's PARTSTAT in an
    /// attendee's object it schedules (RFC 6638: any with SCHEDULE-AGENT SERVER), with the new
    /// PARTSTAT, and a DECLINED per attendee DELETE of such an
    /// object without `Schedule-Reply: F`.
    public internal(set) var serverReplies: [(uid: String, partstat: String)] = []
    /// Every object a PUT created, as it was created: (uid, iCalendar text).
    public internal(set) var created: [(uid: String, ics: String)] = []
    // swiftlint:disable:next large_tuple
    public var requests: [(method: String, path: String, authorization: String?)] { core.requests }

    public init(user: String = "jk@example.org", password: String = "secret", offersSyncCollection: Bool = true) {
        core = FakeDAVCore(user: user, password: password, wellKnown: "/.well-known/caldav")
        self.offersSyncCollection = offersSyncCollection
    }

    public func start() async throws -> UInt16 {
        try await startServer()
    }

    public func stop() {
        stopServer()
    }

    // MARK: - State

    @discardableResult
    func store(_ ics: String, uid: String, in path: String) -> String? {
        guard calendars[path] != nil else {
            return nil
        }
        let now = bump()
        let etag = "\"\(now)\""
        let tag = calendars[path]?.events[uid]?.scheduleTag
        calendars[path]?.events[uid] = Event(ics: ics, etag: etag, modified: now, scheduleTag: tag)
        calendars[path]?.removed[uid] = nil
        calendars[path]?.ctag = now
        return etag
    }

    func remove(uid: String, in path: String) {
        guard calendars[path]?.events[uid] != nil else {
            return
        }
        let now = bump()
        calendars[path]?.events[uid] = nil
        calendars[path]?.removed[uid] = now
        calendars[path]?.ctag = now
    }

    static func key(_ calendar: URL) -> String {
        FakeDAVCore.key(calendar)
    }

    static func eventPath(_ calendar: String, _ uid: String) -> String {
        FakeDAVCore.memberPath(calendar, uid, suffix: ".ics")
    }

    func locate(_ path: String) -> Location {
        if path == "/" || path == Self.principal {
            return .principal
        }
        if path == Self.home {
            return .home
        }
        if calendars[path] != nil {
            return .calendar(path)
        }
        guard path.hasSuffix(".ics"), let slash = path.lastIndex(of: "/") else {
            return .none
        }
        let calendar = String(path[...slash])
        let name = path[path.index(after: slash)...].dropLast(4)
        guard calendars[calendar] != nil, !name.isEmpty else {
            return .none
        }
        return .event(calendar: calendar, uid: name.removingPercentEncoding ?? String(name))
    }

    // MARK: - Serving

    func dropsAnswer(_ request: FakeHTTPRequest) -> Bool {
        if request.method == "DELETE", dropDeleteAnswer {
            dropDeleteAnswer = false
            return true
        }
        guard request.method == "PUT", dropPutAnswer else {
            return false
        }
        dropPutAnswer = false
        return true
    }

    func handle(_ request: FakeHTTPRequest) -> Data {
        switch request.method {
        case "PROPFIND": return propfind(request)
        case "REPORT": return report(request)
        case "PUT": return put(request)
        case "DELETE": return delete(request)
        case "OPTIONS":
            let classes = "1, 3, calendar-access" + (autoSchedules ? ", calendar-auto-schedule" : "")
            return FakeHTTP.response(200, headers: [("DAV", classes)])
        default: return FakeHTTP.response(405)
        }
    }

    private func put(_ request: FakeHTTPRequest) -> Data {
        guard case let .event(path, uid) = locate(request.path), let calendar = calendars[path] else {
            return FakeHTTP.response(409)
        }
        let existing = calendar.events[uid]
        if let refusal = FakeDAVCore.putRefusal(request, existing: existing?.etag, readOnly: calendar.readOnly) {
            return refusal
        }
        let text = fakeText(request.body)
        // RFC 6638 › 3.2.2.1: an attendee may not change the SCHEDULE-AGENT of a scheduling object.
        if let existing, existing.scheduleTag != nil,
            Self.organizerAgent(existing.ics) != Self.organizerAgent(text) {
            let error = "<D:error xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
                + "<C:allowed-attendee-scheduling-object-change/></D:error>"
            return FakeHTTP.response(412, body: Data(error.utf8))
        }
        if let existing, refusesAttendeeChanges, isAttendees(text),
            Self.organiserFields(existing.ics) != Self.organiserFields(text) {
            let error = "<D:error xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
                + "<C:allowed-attendee-scheduling-object-change/></D:error>"
            return FakeHTTP.response(403, body: Data(error.utf8))
        }
        // RFC 6638 › 3.2.2.3: a PARTSTAT changed over an attendee's object the server schedules
        // (SCHEDULE-AGENT SERVER, the default) is a REPLY from here. A create replies to no one
        // (› 3.2.2.2 leaves it unsaid).
        var tag = existing?.scheduleTag
        if let existing, isAttendeeScheduled(text) {
            let before = Self.ownPartstatsByOccurrence(existing.ics, core.user)
            let after = Self.ownPartstatsByOccurrence(text, core.user)
            // The series (an empty key) first, then the occurrences by their RECURRENCE-ID.
            if let changed = after.keys.sorted().first(where: { before[$0] != after[$0] }),
                let partstat = after[changed] {
                serverReplies.append((uid, partstat))
                if tag == nil {
                    scheduleCount += 1
                    tag = "\"st-\(scheduleCount)\""
                }
            }
        }
        if existing == nil {
            created.append((uid, text))
        }
        let etag = store(text, uid: uid, in: path) ?? ""
        if existing == nil, changeNextCreate {
            changeNextCreate = false
            store(text + "\r\n", uid: uid, in: path)
        }
        calendars[path]?.events[uid]?.scheduleTag = tag
        var headers = [("ETag", etag)]
        if let tag, !putsWithoutScheduleTag {
            headers.append(("Schedule-Tag", tag))
        }
        return FakeHTTP.response(existing == nil ? 201 : 204, headers: headers)
    }

    /// The object is an attendee's that the server schedules: its ORGANIZER is someone else, with no
    /// SCHEDULE-AGENT CLIENT or NONE, and the account is among its ATTENDEEs.
    private func isAttendeeScheduled(_ ics: String) -> Bool {
        isAttendees(ics) && autoSchedules && Self.organizerAgent(ics) == "SERVER"
    }

    /// The SCHEDULE-AGENT on the first ORGANIZER, SERVER when it has none.
    static func organizerAgent(_ ics: String) -> String {
        guard let organizer = unfolded(ics).first(where: { $0.uppercased().hasPrefix("ORGANIZER") }) else {
            return "SERVER"
        }
        return organizer.firstMatch(of: /;SCHEDULE-AGENT=([A-Za-z-]+)/).map { String($0.output.1).uppercased() }
            ?? "SERVER"
    }

    /// The PARTSTAT of every ATTENDEE line for `user`, in order (NEEDS-ACTION when it has none).
    public static func ownPartstats(_ ics: String, _ user: String) -> [String] {
        unfolded(ics).filter { isOwn($0, user) }.map(partstat)
    }

    /// The PARTSTAT for `user` per VEVENT, keyed by its RECURRENCE-ID value ("" for the series).
    static func ownPartstatsByOccurrence(_ ics: String, _ user: String) -> [String: String] {
        var found: [String: String] = [:]
        var recurrence = ""
        var own: String?
        for line in unfolded(ics) {
            if line == "BEGIN:VEVENT" {
                (recurrence, own) = ("", nil)
            } else if line == "END:VEVENT" {
                if let own { found[recurrence] = own }
            } else if line.uppercased().hasPrefix("RECURRENCE-ID"), let colon = line.lastIndex(of: ":") {
                recurrence = String(line[line.index(after: colon)...])
            } else if isOwn(line, user) {
                own = partstat(line)
            }
        }
        return found
    }

    static func unfolded(_ ics: String) -> [String] {
        var lines: [String] = []
        for line in ics.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let last = lines.popLast() {
                lines.append(last + line.dropFirst())
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    static func isOwn(_ line: String, _ user: String) -> Bool {
        line.uppercased().hasPrefix("ATTENDEE") && line.lowercased().hasSuffix(":mailto:" + user.lowercased())
    }

    private static func partstat(_ line: String) -> String {
        line.firstMatch(of: /;PARTSTAT=([A-Za-z-]+)/).map { String($0.output.1).uppercased() } ?? "NEEDS-ACTION"
    }

    private func delete(_ request: FakeHTTPRequest) -> Data {
        guard case let .event(path, uid) = locate(request.path), let calendar = calendars[path],
            let event = calendar.events[uid]
        else {
            return FakeHTTP.response(404)
        }
        if let refusal = FakeDAVCore.deleteRefusal(request, etag: event.etag, readOnly: calendar.readOnly) {
            return refusal
        }
        // RFC 6638 › 8.1: an attendee deleting an object the server schedules declines, unless the
        // request says `Schedule-Reply: F`.
        if event.scheduleTag != nil, request.headers["schedule-reply"]?.uppercased() != "F",
            !Self.ownPartstats(event.ics, core.user).isEmpty,
            !Self.unfolded(event.ics).contains(where: {
                $0.uppercased().hasPrefix("ORGANIZER") && $0.lowercased().hasSuffix(":mailto:" + core.user.lowercased())
            }) {
            serverReplies.append((uid, "DECLINED"))
        }
        remove(uid: uid, in: path)
        return FakeHTTP.response(204)
    }
}

// MARK: - Test controls

extension FakeCalDAVServer {
    public func addCalendar(
        _ name: String, color: String? = nil, components: [String] = ["VEVENT"], readOnly: Bool = false
    ) -> URL {
        calendarCount += 1
        let path = "\(Self.home)c\(calendarCount)/"
        calendars[path] = Calendar(
            name: name, color: color, components: components, readOnly: readOnly, ctag: bump())
        return url(path)
    }

    public func putEvent(_ ics: String, uid: String, in calendar: URL) {
        store(ics, uid: uid, in: Self.key(calendar))
    }

    /// `action` runs once as the next PUT arrives, before it is answered (the owner editing while
    /// a send is in flight, say).
    public func beforeNextPut(_ action: @escaping @Sendable () -> Void) {
        core.beforeNextPut = action
    }

    /// The next PUT is carried out but never answered: the connection closes instead.
    public func dropNextPutAnswer() {
        dropPutAnswer = true
    }

    /// The next DELETE is carried out but never answered: the connection closes instead.
    public func dropNextDeleteAnswer() {
        dropDeleteAnswer = true
    }

    /// The next lookup of a UID (a calendar-query on it) fails with the server's trouble.
    public func refuseNextUIDLookup() {
        refuseUIDLookup = true
    }

    /// From now on the server does not schedule: it no longer says so, and sends no replies.
    public func stopAutoScheduling() {
        autoSchedules = false
    }

    /// The next create is changed by the server as it is stored (its ETag moves past the answer's).
    public func changeTheNextCreateOnStore() {
        changeNextCreate = true
    }

    /// From now on, PUT answers carry no `Schedule-Tag`.
    public func answerPutsWithoutScheduleTag() {
        putsWithoutScheduleTag = true
    }

    /// The object is kept by the server's own scheduling from now on: it gets a `Schedule-Tag`, and
    /// the owner's answers written to it are sent to the organiser by this server (`serverReplies`).
    public func markScheduled(uid: String, in calendar: URL) {
        scheduleCount += 1
        calendars[Self.key(calendar)]?.events[uid]?.scheduleTag = "\"st-\(scheduleCount)\""
    }

    public func removeEvent(uid: String, in calendar: URL) {
        remove(uid: uid, in: Self.key(calendar))
    }

    public func removeCalendar(_ calendar: URL) {
        calendars[Self.key(calendar)] = nil
        core.revision += 1
    }

    /// uid → iCalendar text.
    public func events(in calendar: URL) -> [String: String] {
        calendars[Self.key(calendar)]?.events.mapValues(\.ics) ?? [:]
    }

    /// Every sync token handed out so far stops being valid.
    public func forgetSyncTokens() {
        core.epoch += 1
    }

    public func redirectWellKnown(to target: String) {
        core.wellKnownTarget = target
    }

    /// `path` answers 301 to `target` (for an authorised request).
    public func redirect(_ path: String, to target: String) {
        core.redirects[path] = target
    }
}
