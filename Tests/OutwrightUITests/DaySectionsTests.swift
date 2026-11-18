// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightUI

@Suite struct DaySectionsTests {
    private func row(_ id: Int64, _ date: Date) -> MessageRow {
        MessageRow(
            id: MessageID(raw: id), accountID: AccountID(), folderID: FolderID(raw: 1), uid: UInt32(id),
            threadID: ThreadID(raw: "\(id)"), from: Address(name: nil, email: "bo@example.org"), to: [], cc: [],
            subject: "", preview: "", date: date, isRead: true, isFlagged: false, hasAttachment: false,
            isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
    }

    @Test func groupsTodayYesterdayWeekdaysDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "sv_SE")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        // Friday 6 November 2026, 15:00.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15)))
        func day(_ offset: Int, hour: Int = 9) throws -> Date {
            let start = try #require(calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)))
            return try #require(calendar.date(byAdding: .hour, value: hour, to: start))
        }
        let rows = [
            row(1, try day(0, hour: 14)), row(2, try day(0, hour: 8)), row(3, try day(-1)), row(4, try day(-3)),
            row(5, try day(-30)),
        ]
        let sections = DaySections.group(rows, now: now, calendar: calendar)
        #expect(sections.prefix(3).map(\.title) == ["I dag", "I går", "tisdag"])
        #expect(sections.count == 4)
        #expect(sections.map { $0.rows.map(\.id.raw) } == [[1, 2], [3], [4], [5]])
    }

    @Test func englishTitles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15)))
        let yesterday = now.addingTimeInterval(-86_400)
        let sections = DaySections.group([row(1, now), row(2, yesterday)], now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday"])
    }

    /// The reading header gives the time for older mail too, not only today's.
    @Test func readingLabelHasTimeForOlderMail() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "sv_SE")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let sent = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 20)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15)))
        let label = DaySections.readingLabel(sent, now: now, calendar: calendar)
        #expect(label.contains("09:20"))
        #expect(label.contains("12"))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 20)))
        #expect(DaySections.readingLabel(today, now: now, calendar: calendar) == "09:20")
    }
}
