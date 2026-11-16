// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A VTIMEZONE, as Sync maps it.
public struct ZoneRules: Sendable, Equatable, Codable {
    public var observances: [Observance]

    public init(observances: [Observance]) { self.observances = observances }
}

/// One STANDARD or DAYLIGHT block of a VTIMEZONE.
public struct Observance: Sendable, Equatable, Codable {
    public var isDaylight: Bool
    /// DTSTART: local wall time in `offsetFrom`.
    public var start: DateComponents
    /// TZOFFSETFROM and TZOFFSETTO, in seconds east of UTC.
    public var offsetFrom: Int
    public var offsetTo: Int
    public var rule: RecurrenceRule?
    public var rdates: [DateComponents]

    public init(isDaylight: Bool, start: DateComponents, offsetFrom: Int, offsetTo: Int,
                rule: RecurrenceRule? = nil, rdates: [DateComponents] = []) {
        self.isDaylight = isDaylight
        self.start = start
        self.offsetFrom = offsetFrom
        self.offsetTo = offsetTo
        self.rule = rule
        self.rdates = rdates
    }
}

public enum ResolvedZone: Sendable, Equatable {
    case iana(String)
    case rules(ZoneRules)
    case floating
}

public enum ZoneResolver {
    /// An IANA id the system knows; else a Windows zone name; else the calendar object's own VTIMEZONE;
    /// else floating.
    public static func resolve(tzid: String, given: [String: ZoneRules]) -> ResolvedZone {
        if tzid.utf8.count <= 128 {
            if TimeZone(identifier: tzid) != nil { return .iana(tzid) }
            if let iana = WindowsZones.table[tzid] { return .iana(iana) }
        }
        if let rules = given[tzid] { return .rules(rules) }
        return .floating
    }
}
