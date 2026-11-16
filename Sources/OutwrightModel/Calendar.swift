// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public struct CalendarID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct EventID: Hashable, Codable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

public struct CalendarInfo: Sendable, Identifiable, Equatable {
    public var id: CalendarID
    /// The account whose server holds the calendar; nil for a subscribed calendar, which belongs to
    /// no account.
    public var accountID: AccountID?
    public var href: String
    public var name: String
    /// 0xRRGGBB.
    public var color: Int
    public var isReadOnly: Bool
    public var isDefault: Bool

    public init(
        id: CalendarID, accountID: AccountID?, href: String, name: String, color: Int, isReadOnly: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.accountID = accountID
        self.href = href
        self.name = name
        self.color = color
        self.isReadOnly = isReadOnly
        self.isDefault = isDefault
    }
}

/// Why a subscribed calendar's last fetch failed.
public enum SubscriptionFailure: String, Error, Sendable, Codable, CaseIterable {
    /// No connection, or TLS failed.
    case unreachable
    /// 401 or 403: the calendar is no longer shared.
    case unshared
    /// 404 or 410: the calendar is no longer published.
    case unpublished
    /// The answer is not iCalendar.
    case notCalendar
    /// The answer is past a cap.
    case tooLarge
    /// Any other answer from the server.
    case server
    /// The keychain holds no address for it.
    case noAddress
}

/// A calendar read from a published iCalendar address: read-only, of an account the owner picked.
/// The address itself is in the keychain under `key`; only its host is here.
public struct CalendarSubscription: Sendable, Equatable, Identifiable {
    public var calendar: CalendarInfo
    public var key: UUID
    public var host: String
    public var fetchedAt: Date?
    public var failure: SubscriptionFailure?
    public var id: CalendarID { calendar.id }

    public init(calendar: CalendarInfo, key: UUID, host: String, fetchedAt: Date?, failure: SubscriptionFailure?) {
        self.calendar = calendar
        self.key = key
        self.host = host
        self.fetchedAt = fetchedAt
        self.failure = failure
    }
}

/// The colour of a calendar the server gave none for: a pure function of the account and the
/// calendar's address, the same on every run.
public enum CalendarPalette {
    public static let colors = [
        0x2F6FDB, 0xD9534F, 0x2E9E6B, 0xE08A1E, 0x8E5BD0, 0x1B9AAA, 0xC2478A, 0x7A8B3A
    ]

    /// FNV-1a 64 of the account's id (none for a subscribed calendar) and the href, never Swift's
    /// per-run seeded `Hasher`.
    public static func color(account: AccountID?, href: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ((account?.raw.uuidString ?? "") + href).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// One occurrence of an event as the views draw it.
public struct CalendarEvent: Sendable, Identifiable, Equatable {
    /// The series' id: every occurrence of a series shares it.
    public var id: EventID
    public var calendarID: CalendarID
    /// Nil for an event of a subscribed calendar, which belongs to no account.
    public var accountID: AccountID?
    public var occurrence: Occurrence
    public var isSeries: Bool
    public var isEditable: Bool
    /// From `EventOwnership.isTentative` only: drives the striped drawing.
    public var isTentative: Bool
    /// The owner's version, held beside the server's after a conflict: the last of the held changes.
    public var conflict: EventEdit?
    /// How many of the owner's changes the conflict holds; Apply again sends them all, in order.
    public var conflictChanges: Int
    public var changeFailed: Bool
    /// The server took the owner's answer, but its reply mail could not be queued (no Drafts folder):
    /// `changeFailed` is set too; Retry queues the answer again.
    public var replyFailed: Bool
    /// Who wrote the calendar object: the server (its own scheduling, or another client) or this app.
    public var origin: CopyOrigin
    /// STATUS:CANCELLED: the organiser called it off.
    public var isCancelled: Bool
    /// From `EventOwnership.isInvitation` only: the owner may answer it, not change it.
    public var isInvitation: Bool
    /// The owner's own answer, when the owner is an attendee.
    public var ownResponse: Attendee.Response?
    /// The owner's last answer was to go without a response, and the server sent the organiser one
    /// anyway: it had scheduled the copy by the time the answer reached it.
    public var replySentByServer: Bool

    public init(
        id: EventID, calendarID: CalendarID, accountID: AccountID?, occurrence: Occurrence, isSeries: Bool,
        isEditable: Bool, isTentative: Bool, conflict: EventEdit? = nil, conflictChanges: Int? = nil,
        changeFailed: Bool = false, origin: CopyOrigin = .server, isCancelled: Bool = false,
        isInvitation: Bool = false, ownResponse: Attendee.Response? = nil, replyFailed: Bool = false,
        replySentByServer: Bool = false
    ) {
        self.replySentByServer = replySentByServer
        self.id = id
        self.calendarID = calendarID
        self.accountID = accountID
        self.occurrence = occurrence
        self.isSeries = isSeries
        self.isEditable = isEditable
        self.isTentative = isTentative
        self.conflict = conflict
        self.conflictChanges = conflictChanges ?? (conflict == nil ? 0 : 1)
        self.changeFailed = changeFailed
        self.replyFailed = replyFailed
        self.origin = origin
        self.isCancelled = isCancelled
        self.isInvitation = isInvitation
        self.ownResponse = ownResponse
    }
}

public enum EditScope: Sendable, Equatable, Codable {
    /// A single event, or the whole series.
    case event
    case occurrence(EventTime)
}

public enum EventEdit: Sendable, Equatable, Codable {
    case create(EventDetails, rule: RecurrenceRule?)
    case update(EventDetails, rule: RecurrenceRule?, scope: EditScope)
    case delete(scope: EditScope)
    /// The owner's answer to an invitation; `sendReply` false keeps the answer from the organiser.
    case respond(Attendee.Response, scope: EditScope, sendReply: Bool)
    /// The owner's own reminder on an invitation, in minutes before the start; nil for none.
    case ownReminder(Int?, scope: EditScope)
    /// A guest's answer to the owner's meeting, from their REPLY by mail (RFC 6047), written to a
    /// CalDAV server that does not take REPLYs itself.
    case guestAnswer(email: String, response: Attendee.Response, scope: EditScope)
    /// The organiser's update or cancellation of an invitation, from mail (RFC 6047), written to the
    /// owner's copy on the server (RFC 6638 › 3.2.2.2). It changes nothing itself: the object it is
    /// written onto is the organiser's change already.
    case organiserChange
}

/// Who wrote a calendar object: the server (its own scheduling put an invitation there, or another
/// client did) or this app (from an invitation in mail).
public enum CopyOrigin: String, Sendable, Codable {
    case server, app
}

/// The iTIP methods an invitation in mail is read for. The same four values as the DAV layer's
/// `ITIPMethod`, which the model cannot see; Sync maps one to the other by raw value.
public enum InvitationMethod: String, Sendable, Codable {
    case request = "REQUEST", add = "ADD", cancel = "CANCEL", reply = "REPLY"
}

/// What the store knows of the invitation a message carries.
public struct InvitationState: Sendable, Equatable {
    public var method: InvitationMethod
    /// The event it is about, when the calendar holds it.
    public var event: CalendarEvent?
    /// The message's SEQUENCE.
    public var sequence: Int
    /// A newer SEQUENCE for the same event is already applied.
    public var isOutdated: Bool
    /// False: the sender check failed, or there was nothing to apply.
    public var wasApplied: Bool
    /// For a REPLY: who answered, and how.
    public var reply: (email: String, response: Attendee.Response)?
    /// The occurrence the message is about, as the message names it; nil for the whole event.
    public var recurrenceID: EventTime?
    /// A later version of a meeting the calendar already held (the phone or the server applied it).
    public var isUpdate: Bool
    /// For an update the phone applied: whether its time moved. Nil when unknown or not an update.
    public var timeMoved: Bool?
    /// The meeting's title as the message gave it, for when the calendar no longer holds the event.
    public var title: String?

    public init(
        method: InvitationMethod, event: CalendarEvent?, sequence: Int, isOutdated: Bool, wasApplied: Bool,
        reply: (email: String, response: Attendee.Response)? = nil, recurrenceID: EventTime? = nil,
        isUpdate: Bool = false, timeMoved: Bool? = nil, title: String? = nil
    ) {
        self.method = method
        self.event = event
        self.sequence = sequence
        self.isOutdated = isOutdated
        self.wasApplied = wasApplied
        self.reply = reply
        self.recurrenceID = recurrenceID
        self.isUpdate = isUpdate
        self.timeMoved = timeMoved
        self.title = title
    }

    public static func == (lhs: InvitationState, rhs: InvitationState) -> Bool {
        lhs.method == rhs.method && lhs.event == rhs.event && lhs.sequence == rhs.sequence
            && lhs.isOutdated == rhs.isOutdated && lhs.wasApplied == rhs.wasApplied
            && lhs.reply?.email == rhs.reply?.email && lhs.reply?.response == rhs.reply?.response
            && lhs.recurrenceID == rhs.recurrenceID && lhs.isUpdate == rhs.isUpdate
            && lhs.timeMoved == rhs.timeMoved && lhs.title == rhs.title
    }
}
