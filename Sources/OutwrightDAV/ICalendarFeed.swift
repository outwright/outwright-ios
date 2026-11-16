// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation

/// One calendar object cut from a published calendar: an event's master and overrides (one UID)
/// with the time zones they name, as a CalDAV resource would hold them.
public struct FeedObject: Sendable, Equatable {
    /// `uid:<UID>`, or `nouid:<etag>` for an event without one.
    public let href: String
    /// The lowercase hex SHA-256 of `data`.
    public let etag: String
    public let data: Data
}

/// A published calendar cut into calendar objects.
public struct FeedSplit: Sendable {
    /// The file's `X-WR-CALNAME`.
    public let name: String?
    /// Sorted by href.
    public let objects: [FeedObject]
    /// Events that cannot be kept: no UID, or past one resource's caps.
    public let refused: [FeedObject]
}

/// Cuts one published VCALENDAR (RFC 5545) into one calendar object per UID. Only VEVENTs are
/// kept; VALARMs are dropped (a file someone else publishes does not ring the phone).
public enum ICalendarFeed {
    /// The longest name taken from a file's `X-WR-CALNAME`, in characters.
    public static let nameLength = 200

    public static func split(_ data: Data) throws(ICalError) -> FeedSplit {
        let calendar = try ICalendarReader.feed(data)
        let zones = writtenZones(calendar)
        let found = try grouped(calendar)
        let (order, groups) = (found.order, found.groups)
        var refused = found.refused
        let frame = Frame(calendar.properties.filter { $0.name == "PRODID" })
        var objects: [FeedObject] = []
        var written = 0
        for uid in order {
            let events = groups[uid] ?? []
            let named = zoneNames(events, zones: zones)
            var data = frame.open
            for id in named { data += zones[id]?.data ?? Data() }
            for event in events { data += ICalendarWriter.write(event) }
            data += frame.close
            written += data.count
            guard written <= DAVLimits.feedOutputBytes else { throw .tooLarge }
            let item = FeedObject(href: "uid:" + uid, etag: digest(data), data: data)
            let parts = ICalComponent(name: "VCALENDAR", components: named.compactMap { zones[$0]?.component } + events)
            if fitsOneResource(data, parts) {
                objects.append(item)
            } else {
                refused.append(FeedObject(href: item.href, etag: item.etag, data: Data()))
            }
        }
        return FeedSplit(
            name: calendar.first("X-WR-CALNAME").map { String($0.text.prefix(nameLength)) },
            objects: objects.sorted { $0.href < $1.href }, refused: refused)
    }

    /// The file's zones by TZID, each written once: every object naming it carries these bytes. A
    /// zone past its cap is left out.
    private static func writtenZones(_ calendar: ICalComponent) -> [String: (component: ICalComponent, data: Data)] {
        var zones: [String: (component: ICalComponent, data: Data)] = [:]
        for zone in calendar.components where zone.name == "VTIMEZONE" {
            guard let id = zone.first("TZID")?.value, zones[id] == nil else { continue }
            let written = ICalendarWriter.write(zone)
            guard written.count <= DAVLimits.feedZoneBytes else { continue }
            zones[id] = (zone, written)
        }
        return zones
    }

    /// The VEVENTs (VALARMs dropped) by UID in first-seen order, and those without a UID refused.
    private static func grouped(_ calendar: ICalComponent) throws(ICalError) -> Grouped {
        var order: [String] = []
        var groups: [String: [ICalComponent]] = [:]
        var refused: [FeedObject] = []
        for event in calendar.components where event.name == "VEVENT" {
            let quiet = ICalComponent(
                name: event.name, properties: event.properties,
                components: event.components.filter { $0.name != "VALARM" })
            let uid = quiet.first("UID")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isNew = uid.isEmpty || groups[uid] == nil
            guard !isNew || order.count + refused.count < DAVLimits.feedObjects else { throw .tooLarge }
            guard !uid.isEmpty else {
                let tag = digest(ICalendarWriter.write(quiet))
                refused.append(FeedObject(href: "nouid:" + tag, etag: tag, data: Data()))
                continue
            }
            if isNew { order.append(uid) }
            groups[uid, default: []].append(quiet)
        }
        return Grouped(order: order, groups: groups, refused: refused)
    }

    private struct Grouped {
        var order: [String]
        var groups: [String: [ICalComponent]]
        var refused: [FeedObject]
    }

    /// The written start of every object (`BEGIN:VCALENDAR`, VERSION, the file's PRODID) and its end.
    private struct Frame {
        let open: Data
        let close = Data("END:VCALENDAR\r\n".utf8)

        init(_ head: [ICalProperty]) {
            let whole = ICalendarWriter.write(
                ICalComponent(name: "VCALENDAR", properties: [ICalProperty(name: "VERSION", value: "2.0")] + head))
            open = whole.count >= close.count ? whole.dropLast(close.count) : whole
        }
    }

    /// The zones the events' properties name, in the order first named.
    private static func zoneNames(
        _ events: [ICalComponent], zones: [String: (component: ICalComponent, data: Data)]
    ) -> [String] {
        var named: [String] = []
        var seen: Set<String> = []
        for event in events {
            for property in event.properties {
                if let id = property.parameter("TZID"), zones[id] != nil, seen.insert(id).inserted { named.append(id) }
            }
        }
        return named
    }

    /// Whether an object is within one CalDAV resource's caps as `ICalendarReader.calendar` reads
    /// them: its bytes and its components. Lines, depth and properties were capped alike when the
    /// file was read.
    private static func fitsOneResource(_ data: Data, _ calendar: ICalComponent) -> Bool {
        guard data.count <= DAVLimits.iCalendarBytes else { return false }
        var components = 0
        var stack = [calendar]
        while let next = stack.popLast() {
            components += 1
            guard components <= DAVLimits.componentsPerResource else { return false }
            stack += next.components
        }
        return true
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
