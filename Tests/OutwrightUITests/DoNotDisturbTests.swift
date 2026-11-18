// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct DoNotDisturbTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func doNotDisturbEndsByItself() {
        let dnd = DoNotDisturb.untilOneHour(from: start)
        #expect(dnd.isActive(at: start))
        #expect(dnd.isActive(at: start.addingTimeInterval(3599)))
        #expect(!dnd.isActive(at: start.addingTimeInterval(3601)))
        #expect(!DoNotDisturb().isActive(at: start))
    }

    @Test func untilTomorrowMorningIsEightNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let evening = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 22, minute: 30)))
        let until = try #require(DoNotDisturb.untilTomorrowMorning(from: evening, calendar: calendar).until)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        #expect((parts.day, parts.hour, parts.minute) == (17, 8, 0))
    }

    /// The bell checks the choice the owner made, also in its last hour.
    @Test func theCheckMarkIsTheChoiceMade() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let evening = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 22, minute: 30)))
        let tomorrow = DoNotDisturb.untilTomorrowMorning(from: evening, calendar: calendar)
        let morning = try #require(tomorrow.until)
        #expect(tomorrow.choice(at: evening) == .tomorrowMorning)
        #expect(tomorrow.choice(at: morning.addingTimeInterval(-1_800)) == .tomorrowMorning)
        #expect(tomorrow.choice(at: morning.addingTimeInterval(1)) == nil)
        let hour = DoNotDisturb.untilOneHour(from: evening)
        #expect(hour.choice(at: evening) == .oneHour)
        #expect(DoNotDisturb().choice(at: evening) == nil)
    }

    /// The choice is kept with the value; one stored before it was kept still reads, its choice told by
    /// the time left.
    @Test func theChoiceIsKeptAndOldValuesStillRead() throws {
        let defaults = try #require(UserDefaults(suiteName: "dnd-\(UUID().uuidString)"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let tomorrow = DoNotDisturb.untilTomorrowMorning(from: start, calendar: calendar)
        DoNotDisturbDefaults.save(tomorrow, to: defaults)
        let until = try #require(tomorrow.until)
        #expect(DoNotDisturbDefaults.load(from: defaults).choice(at: until.addingTimeInterval(-60)) == .tomorrowMorning)
        let old = Data(#"{"until":\#(start.addingTimeInterval(7_200).timeIntervalSinceReferenceDate)}"#.utf8)
        defaults.set(old, forKey: DoNotDisturb.defaultsKey)
        let read = DoNotDisturbDefaults.load(from: defaults)
        #expect(read.until == start.addingTimeInterval(7_200))
        #expect(read.choice(at: start) == .tomorrowMorning)
        #expect(read.choice(at: start.addingTimeInterval(3_700)) == .oneHour)
    }

    @Test func itIsKeptInTheSharedDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "dnd-\(UUID().uuidString)"))
        #expect(!DoNotDisturbDefaults.load(from: defaults).isActive(at: start))
        DoNotDisturbDefaults.save(.untilOneHour(from: start), to: defaults)
        #expect(DoNotDisturbDefaults.load(from: defaults).isActive(at: start))
    }

    @Test func theBellWritesTheStoredValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "dnd-\(UUID().uuidString)"))
        let store = try MailStore(path: nil)
        let app = AppModel(store: store, sync: offlineSync(store: store, secrets: InMemorySecretStore()))
        app.setDoNotDisturb(.untilOneHour(from: Date()), defaults: defaults)
        #expect(app.doNotDisturb(defaults: defaults).isActive(at: Date()))
        app.setDoNotDisturb(DoNotDisturb(), defaults: defaults)
        #expect(!app.doNotDisturb(defaults: defaults).isActive(at: Date()))
    }

    /// Turning the bell on or off, and its end coming by itself, plans the reminders again, so the ones
    /// already with the phone are quieted or get their sound back.
    @Test func theBellPlansTheRemindersAgain() async throws {
        let defaults = try #require(UserDefaults(suiteName: "dnd-\(UUID().uuidString)"))
        let store = try MailStore(path: nil)
        let reminders = KeptReminders()
        let app = AppModel(
            store: store, sync: offlineSync(store: store, secrets: InMemorySecretStore(), reminders: reminders))
        app.setDoNotDisturb(DoNotDisturb(until: Date().addingTimeInterval(0.3)), defaults: defaults)
        await app.doNotDisturbReplan?.value
        #expect(await reminders.handovers == 1)
        await app.doNotDisturbEnd?.value
        await app.doNotDisturbReplan?.value
        #expect(await reminders.handovers == 2)
        app.setDoNotDisturb(DoNotDisturb(), defaults: defaults)
        await app.doNotDisturbReplan?.value
        #expect(await reminders.handovers == 3)
    }
}
