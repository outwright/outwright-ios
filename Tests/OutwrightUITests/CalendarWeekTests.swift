// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

/// The calendar in landscape: a week, or a work week, around the anchor.
@MainActor @Suite struct CalendarWeekTests {
    /// The days shown, as day-of-month numbers.
    private func shownDays(_ model: CalendarModel, _ locale: String = "sv_SE") -> [Int] {
        model.days.map { phoneCalendar(locale).component(.day, from: $0.day) }
    }

    private func landscape(_ fixture: CalendarFixture, _ locale: String = "sv_SE", anchor day: Int) -> CalendarModel {
        let model = fixture.model(locale)
        model.anchorDay = fixture.at(day: day, 12)
        model.isLandscape = true
        return model
    }

    @Test func landscapeWeekStartsOnTheLocalesFirstWeekday() throws {
        let model = landscape(try CalendarFixture(), anchor: 11)
        #expect(shownDays(model) == [9, 10, 11, 12, 13, 14, 15])
    }

    @Test func landscapeWeekFollowsASundayFirstLocale() throws {
        let model = landscape(try CalendarFixture(), "en_US", anchor: 11)
        #expect(shownDays(model, "en_US") == [8, 9, 10, 11, 12, 13, 14])
    }

    @Test func workWeekIsMondayToFriday() throws {
        let model = landscape(try CalendarFixture(), "en_US", anchor: 11)
        model.weekMode = .workWeek
        #expect(shownDays(model, "en_US") == [9, 10, 11, 12, 13])
    }

    @Test func workWeekOnASundayShowsThatMondaysWeek() throws {
        let model = landscape(try CalendarFixture(), anchor: 15)
        model.weekMode = .workWeek
        #expect(shownDays(model) == [9, 10, 11, 12, 13])
    }

    @Test func weekCrossesAClockChange() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        let calendar = phoneCalendar()
        // The clocks go back on Sunday 25 October 2026 in Stockholm.
        model.anchorDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)))
        model.isLandscape = true
        #expect(shownDays(model) == [19, 20, 21, 22, 23, 24, 25])
        #expect(model.days.allSatisfy { calendar.component(.hour, from: $0.day) == 0 })
    }

    @Test func weekCrossesAMonth() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.anchorDay = try #require(
            phoneCalendar().date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)))
        model.isLandscape = true
        #expect(shownDays(model) == [26, 27, 28, 29, 30, 31, 1])
    }

    @Test func workWeekOnASaturdayShowsThatMondaysWeek() throws {
        let model = landscape(try CalendarFixture(), anchor: 14)
        model.weekMode = .workWeek
        #expect(shownDays(model) == [9, 10, 11, 12, 13])
    }

    @Test func swipeMovesAWeekInLandscape() throws {
        let model = landscape(try CalendarFixture(), anchor: 11)
        model.step(1)
        #expect(shownDays(model) == [16, 17, 18, 19, 20, 21, 22])
    }

    @Test func turningBackShowsThePortraitViewOnTheSameDates() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        model.mode = .threeDay
        model.anchorDay = fixture.at(day: 11, 12)
        model.isLandscape = true
        model.step(1)
        model.isLandscape = false
        #expect(model.mode == .threeDay)
        #expect(shownDays(model) == [18, 19, 20])
    }

    @Test func everyPortraitViewTurnsIntoTheWeek() throws {
        let fixture = try CalendarFixture()
        for mode in CalendarMode.allCases {
            let model = fixture.model()
            model.mode = mode
            model.anchorDay = fixture.at(day: 11, 12)
            model.isLandscape = true
            #expect(model.showsWeek)
            #expect(shownDays(model) == [9, 10, 11, 12, 13, 14, 15])
        }
    }

    @Test func regularWidthDefaultsToWeek() throws {
        let fixture = try CalendarFixture()
        let model = fixture.model()
        #expect(!model.offeredModes.contains(.week))
        model.isRegularWidth = true
        #expect(model.mode == .week)
        #expect(model.showsWeek)
        #expect(model.days.count == 7)
        #expect(model.offeredModes.contains(.week) && model.offeredModes.contains(.workWeek))
        model.mode = .workWeek
        #expect(model.days.count == 5)
        // A view once chosen is kept, on a wide screen as well.
        let defaults = freshDefaults()
        fixture.model(defaults: defaults).mode = .day
        let chosen = fixture.model(defaults: defaults)
        chosen.isRegularWidth = true
        #expect(chosen.mode == .day)
    }
}
