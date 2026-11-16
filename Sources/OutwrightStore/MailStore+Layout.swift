// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB

/// Laying the events out over the calendar window again, and remembering for which day it was done.
extension MailStore {
    /// The day (yyyymmdd) and phone zone every event was last laid out for, by `reexpandAll`; nil
    /// before it ever ran. Kept in the store, so a new start of the app on the same day knows it.
    public func laidOut() throws(StoreError) -> (day: Int, zone: String)? {
        try read { database in
            let rows = try Row.fetchAll(
                database, sql: "SELECT key, value FROM calendar_meta WHERE key IN ('laidOutDay', 'laidOutZone')")
            var values: [String: String] = [:]
            for row in rows {
                if let key = row["key"] as String?, let value = row["value"] as String? { values[key] = value }
            }
            guard let day = values["laidOutDay"].flatMap({ Int($0) }), let zone = values["laidOutZone"] else {
                return nil
            }
            return (day, zone)
        }
    }

    /// Lays every event out again, for a window that has moved or a phone that changed time zone,
    /// and notes it was done for `day` (yyyymmdd) in that zone. From the stored series; nothing is fetched.
    public func reexpandAll(window: ClosedRange<Date>, phoneZone: TimeZone, day: Int) throws(StoreError) {
        try write { database in
            let expansion = Expansion(from: window.lowerBound, to: window.upperBound, zone: phoneZone)
            try expansion.save(database)
            for (key, value) in [("laidOutDay", String(day)), ("laidOutZone", phoneZone.identifier)] {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO calendar_meta (key, value) VALUES (?, ?)", arguments: [key, value])
            }
            let rows = try Row.fetchAll(database, sql: "SELECT id, seriesJSON, pendingEditJSON FROM event")
            for row in rows {
                guard let id = row["id"] as Int64? else { continue }
                if CalendarRecords.decodeEdits(row["pendingEditJSON"] as String?).contains(.delete(scope: .event)) {
                    continue
                }
                guard let series = CalendarRecords.decodeSeries(row["seriesJSON"] as String?) else { continue }
                try CalendarRecords.expand(database, event: id, series: series, expansion)
            }
        }
    }
}
