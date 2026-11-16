// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Every bound the DAV module enforces on data from a server. Anything past a cap is
/// refused or dropped, never trusted.
public enum DAVLimits {
    /// An HTTP response body, in bytes.
    public static let responseBytes = 16 * 1024 * 1024
    /// Compliance classes read from one DAV header.
    public static let davClasses = 64
    /// Element nesting in a multistatus document.
    public static let xmlDepth = 32
    /// `response` elements in one multistatus.
    public static let multistatusResponses = 50_000
    /// One vCard resource, in bytes.
    public static let vCardBytes = 1024 * 1024
    /// Properties in one vCard.
    public static let vCardProperties = 2_000
    /// One unfolded content line, in bytes (an inline photo has its own allowance).
    public static let vCardLineBytes = 256 * 1024
    /// An inline photo, decoded, in bytes.
    public static let photoBytes = 512 * 1024
    /// Cards in one address book.
    public static let cardsPerAddressBook = 100_000
    /// Address books in one account.
    public static let addressBooksPerAccount = 100
    /// `name` attributes kept per property in a multistatus (the components of a calendar).
    public static let multistatusNameAttributes = 1_000
    /// HTTP redirects followed for one request.
    public static let redirects = 5
    /// Rounds of one sync-collection the server truncated (507) before giving up.
    public static let syncRounds = 1_000
    /// vCards in one resource.
    public static let cardsPerResource = 16
    /// One iCalendar resource, in bytes.
    public static let iCalendarBytes = 2 * 1024 * 1024
    /// One unfolded iCalendar content line, in bytes: the resource cap bounds it.
    public static let iCalendarLineBytes = iCalendarBytes
    /// Components in one iCalendar resource, nested ones included.
    public static let componentsPerResource = 1_000
    /// Nesting of components, the VCALENDAR counting as the first level.
    public static let componentDepth = 8
    /// Properties in one iCalendar component.
    public static let componentProperties = 2_000
    /// Components in one published calendar file (a subscription), nested ones included; the file's
    /// bytes are capped by `responseBytes`.
    public static let feedComponents = 100_000
    /// Calendar objects (events by UID) in one published calendar file.
    public static let feedObjects = 20_000
    /// One VTIMEZONE of a published calendar, written; a larger one is left out (each object carries
    /// a copy of the zones it names).
    public static let feedZoneBytes = 64 * 1024
    /// Everything one published calendar's objects add up to, written.
    public static let feedOutputBytes = 32 * 1024 * 1024
    /// VALARMs in one event.
    public static let alarmsPerEvent = 10
    /// Resources in one calendar.
    public static let resourcesPerCalendar = 100_000
    /// Calendars in one account.
    public static let calendarsPerAccount = 100
}
