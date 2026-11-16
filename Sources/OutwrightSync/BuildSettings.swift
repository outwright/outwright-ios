// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightPush

/// What a build was made with: values its spec set as build settings, carried into Info.plist
/// and read at launch. The open build sets none of them; whatever is missing is simply not
/// there (no relay, no push). A provider reads its own values with `value(_:)`. Read by the app
/// and its extension.
public struct BuildSettings: Sendable, Equatable {
    /// The push relay; https only.
    public var relay: URL?
    /// The app group the app and its notification extension share.
    public var appGroup: String?
    /// Which APNs the device token belongs to; production unless the build says development.
    public var apnsEnvironment: APNsEnvironment
    /// The test hooks' class names; only the end-to-end build names any.
    public var launchHooks: [String]

    /// Every Outwright value the build set, by Info.plist key.
    private let values: [String: String]

    static let maxLength = 512

    public init(info: [String: Any]) {
        var values: [String: String] = [:]
        for (key, value) in info where key.hasPrefix("Outwright") {
            guard let value = value as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unset build setting reaches Info.plist as nothing, or as its own `$(NAME)`.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), trimmed.utf8.count <= Self.maxLength else { continue }
            values[key] = trimmed
        }
        self.values = values
        func text(_ key: String) -> String? { values[key] }
        relay = text("OutwrightRelay").flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        appGroup = text("OutwrightAppGroup")
        let development = text("OutwrightAPNsEnvironment") == APNsEnvironment.development.rawValue
        apnsEnvironment = development ? .development : .production
        launchHooks = (text("OutwrightLaunchHooks") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A value the build set (an Info.plist key starting with `Outwright`); nil when empty or unset.
    public func value(_ key: String) -> String? {
        values[key]
    }

    /// The running app's or extension's own.
    public static var main: BuildSettings {
        BuildSettings(info: Bundle.main.infoDictionary ?? [:])
    }
}
