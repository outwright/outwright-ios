// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Do Not Disturb: until when new-mail and calendar notices are silenced. Pure data; the app and
/// the notification extension both read it, and both ask `isActive(at:)`.
public struct DoNotDisturb: Codable, Equatable, Sendable {
    /// The key it is kept under in the shared defaults.
    public static let defaultsKey = "doNotDisturb"
    /// Nil: off.
    public var until: Date?
    /// The choice that set `until`; nil in a value stored before the choice was kept.
    public var preset: Preset?

    public init(until: Date? = nil, preset: Preset? = nil) {
        self.until = until
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case until, preset
    }

    /// A preset this version does not know reads as none, so the value itself still holds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        until = try container.decodeIfPresent(Date.self, forKey: .until)
        preset = try? container.decodeIfPresent(Preset.self, forKey: .preset)
    }

    /// Active until `until` has come; it ends by itself.
    public func isActive(at date: Date) -> Bool {
        until.map { date < $0 } ?? false
    }

    /// The bell's choices that set an end.
    public enum Preset: String, Codable, Sendable {
        case oneHour, tomorrowMorning
    }

    /// The choice in force at `date`, for the bell's check mark; nil when off. A value stored without
    /// its choice is told by the time left.
    public func choice(at date: Date) -> Preset? {
        guard isActive(at: date), let until else { return nil }
        return preset ?? (until.timeIntervalSince(date) <= 3_600 ? .oneHour : .tomorrowMorning)
    }

    public static func untilOneHour(from date: Date) -> Self {
        Self(until: date.addingTimeInterval(3600), preset: .oneHour)
    }

    /// 08:00 the next day, in `calendar`.
    public static func untilTomorrowMorning(from date: Date, calendar: Calendar) -> Self {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
            let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        else { return untilOneHour(from: date) }
        return Self(until: morning, preset: .tomorrowMorning)
    }
}
