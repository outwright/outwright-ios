// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension EventEditorModel {
    // MARK: Length and custom repeat

    /// The lengths the Length row offers, in minutes.
    static let durations = [0, 15, 30, 45, 60, 90, 120, 180, 240, 480]

    /// A timed event's length in minutes; setting it moves the end.
    var durationMinutes: Int {
        get { Self.lengthMinutes(end.timeIntervalSince(start)) }
        set { end = start.addingTimeInterval(Double(max(newValue, 0)) * 60) }
    }

    /// The longest length counted, in minutes.
    static let maxMinutes = Int(Int32.max)

    /// Seconds as whole minutes, 0 to `maxMinutes`; 0 for a length that is not a number.
    static func lengthMinutes(_ interval: TimeInterval) -> Int {
        let minutes = interval / 60
        guard !minutes.isNaN else { return 0 }
        return Int(min(max(minutes, 0), Double(maxMinutes)))
    }

    /// A length as the Length row says it: "1 h 30 min".
    func durationText(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = phone
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: Double(minutes) * 60) ?? ""
    }

    /// The custom screen opens: the pattern it shows first. The rule changes only with the owner's
    /// first change there, so backing out of it leaves the event as it was.
    func openCustom() -> CustomRepeat? { customRepeat }

    /// The repeat as the custom screen edits it: the rule to save, or a new weekly one when there is
    /// none; nil for a rule the screen can't show. Setting it replaces the rule.
    var customRepeat: CustomRepeat? {
        get {
            guard let rule = savedRule else { return CustomRepeat(start: start, phone: phone) }
            return CustomRepeat(rule: rule, start: start, phone: phone, zones: series?.zones ?? [:])
        }
        set {
            guard let newValue else { return }
            rule = newValue.rule(startTime: details.start, start: start, phone: phone)
        }
    }
}
