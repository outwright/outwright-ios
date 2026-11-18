// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel

/// Do Not Disturb as kept in the app group's shared defaults, which the app and the notification
/// extension both read (the standard defaults where the build has no app group).
public enum DoNotDisturbDefaults {
    public static var shared: UserDefaults {
        BuildSettings.main.appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public static func load(from defaults: UserDefaults = shared) -> DoNotDisturb {
        guard let data = defaults.data(forKey: DoNotDisturb.defaultsKey),
            let value = try? JSONDecoder().decode(DoNotDisturb.self, from: data)
        else { return DoNotDisturb() }
        return value
    }

    public static func save(_ value: DoNotDisturb, to defaults: UserDefaults = shared) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: DoNotDisturb.defaultsKey)
        }
    }
}
