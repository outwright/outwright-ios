// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightSetup
public import OutwrightSync

/// The app-wide settings the owner chose, as a setup file carries them. Only the keys listed here
/// move; what holds this device's own ids (`shownCalendars`, `calendarColors`) or its own records
/// (whether the default signature was filled in once) stays behind. A restore takes the settings
/// the device has never set; what the owner chose here stays unless the owner takes the file's.
public struct SettingsSetupPart: SetupPart {
    public let name = "settings"
    public let version = 1
    public let title = L10n.string("Settings")

    /// The defaults of the app's own settings.
    nonisolated(unsafe) let defaults: UserDefaults
    /// The app group's shared defaults (Do Not Disturb, the badge), the same as `defaults` where the
    /// build has no app group.
    nonisolated(unsafe) let shared: UserDefaults

    /// The ids of the accounts this device has; the default account is taken only from among them.
    let accounts: @Sendable () -> Set<UUID>

    public init(
        defaults: UserDefaults = .standard, shared: UserDefaults? = nil,
        accounts: @escaping @Sendable () -> Set<UUID> = { [] }
    ) {
        self.defaults = defaults
        self.shared = shared ?? defaults
        self.accounts = accounts
    }

    /// How a setting is stored, and so what a value in a file must be.
    enum Kind {
        case bool
        /// An account's id.
        case accountID
        /// One of the setting's own raw values.
        case choice([String])
    }

    struct Setting {
        var key: String
        var kind: Kind
        var inShared = false
    }

    private static let swipeActions = SwipeAction.allCases.map(\.rawValue)

    /// Every key that carries over, with its stored type. A key not here never moves.
    static let settings: [Setting] = [
        Setting(key: SettingsKeys.focusedInbox, kind: .bool),
        Setting(key: SettingsKeys.backgroundRefresh, kind: .bool),
        Setting(key: SettingsKeys.swipeLeading, kind: .choice(swipeActions)),
        Setting(key: SettingsKeys.swipeTrailing, kind: .choice(swipeActions)),
        Setting(key: SettingsKeys.defaultAccount, kind: .accountID),
        Setting(key: SettingsKeys.calendarMode, kind: .choice(CalendarMode.allCases.map(\.rawValue))),
        Setting(key: SettingsKeys.calendarWeekMode, kind: .choice(WeekMode.allCases.map(\.rawValue))),
        Setting(key: "badge.focusedOnly", kind: .bool, inShared: true)
    ]

    /// The longest account id text read.
    static let maxText = 256
    /// The most entries a file may name; far more than there are settings.
    static let maxEntries = 1_024

    /// The part's JSON, version 1: each setting's value by its key.
    struct Content: Codable {
        var values: [String: Scalar]
    }

    /// A JSON scalar; anything else in its place reads as `other`.
    enum Scalar: Codable, Equatable {
        case bool(Bool)
        case text(String)
        case other

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .text(value)
            } else {
                self = .other
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            case .other: try container.encodeNil()
            }
        }
    }

    // MARK: Reading what this device holds

    private func store(_ setting: Setting) -> UserDefaults { setting.inShared ? shared : defaults }

    /// The value as stored, when it has its own type.
    private func held(_ setting: Setting) -> Scalar? {
        let store = store(setting)
        switch setting.kind {
        case .bool:
            return (store.object(forKey: setting.key) as? Bool).map(Scalar.bool)
        case .accountID, .choice:
            return store.string(forKey: setting.key).map(Scalar.text)
        }
    }

    public func export() async throws(SetupError) -> Data {
        var values: [String: Scalar] = [:]
        for setting in Self.settings {
            if let value = held(setting), accepted(value, for: setting) != nil { values[setting.key] = value }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(Content(values: values)) } catch { throw .malformed }
    }

    // MARK: Reading a file

    /// What a setting would be written as; nil when the value is not of the setting's type or not sane.
    /// With `known`, an account id must be one of those.
    private func accepted(_ value: Scalar, for setting: Setting, known: Set<UUID>? = nil) -> Stored? {
        switch (setting.kind, value) {
        case (.bool, .bool(let flag)):
            return .bool(flag)
        case (.choice(let words), .text(let text)):
            return words.contains(text) ? .text(text) : nil
        case (.accountID, .text(let text)):
            guard text.utf8.count <= Self.maxText, let id = UUID(uuidString: text), known?.contains(id) ?? true
            else { return nil }
            return .text(id.uuidString)
        default:
            return nil
        }
    }

    private enum Stored: Equatable {
        case bool(Bool)
        case text(String)
    }

    private func read(_ content: Data) throws(SetupError) -> [String: Scalar] {
        guard content.count <= SetupBundle.maxPartSize else { throw .tooLarge }
        let values: [String: Scalar]
        do { values = try JSONDecoder().decode(Content.self, from: content).values } catch { throw .malformed }
        guard values.count <= Self.maxEntries else { throw .tooLarge }
        return values
    }

    private static func item(_ setting: Setting) -> SetupItem {
        SetupItem(kind: .settings, label: setting.key)
    }

    public func items() async -> [SetupItem] {
        Self.settings.filter { setting in held(setting).flatMap { accepted($0, for: setting) } != nil }
            .map(Self.item)
    }

    public func summary(of content: Data) throws(SetupError) -> [SetupItem] {
        let values = try read(content)
        return Self.settings.filter { setting in
            values[setting.key].flatMap { accepted($0, for: setting) } != nil
        }.map(Self.item)
    }

    /// The id of the settings' one difference.
    static let differenceID = "settings"

    /// One difference for all the settings, when any the file carries is set on this device to
    /// another value.
    public func differences(in content: Data) async -> [SetupDifference] {
        guard let values = try? read(content) else { return [] }
        let known = accounts()
        guard Self.settings.contains(where: { differs($0, from: values[$0.key], known: known) }) else { return [] }
        return [SetupDifference(kind: .settings, part: name, label: title, id: Self.differenceID)]
    }

    /// Whether the file's value is one this device would take, and the device has set the setting
    /// to something else.
    private func differs(_ setting: Setting, from value: Scalar?, known: Set<UUID>) -> Bool {
        guard let value, let stored = accepted(value, for: setting, known: known),
            store(setting).object(forKey: setting.key) != nil
        else { return false }
        return held(setting).flatMap { accepted($0, for: setting) } != stored
    }

    public func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        await importContent(content, version: version, replacing: [])
    }

    /// Takes the settings the device has never set; with the settings' difference in `replacing`,
    /// also the ones it has set to another value.
    public func importContent(_ content: Data, version: Int, replacing: Set<String>) async -> SetupImportReport {
        guard version <= self.version else { return .notRead(title) }
        guard let values = try? read(content) else { return .unreadable(title) }
        var report = SetupImportReport()
        let known = accounts()
        let replace = replacing.contains(Self.differenceID)
        for setting in Self.settings {
            guard let value = values[setting.key] else { continue }
            let item = Self.item(setting)
            guard let stored = accepted(value, for: setting) else {
                report.skipped.append(SetupSkip(item: item, reason: .failed))
                continue
            }
            // A default account this device does not have is no choice here: the device's own
            // default stays, and there is nothing to tell.
            if case .accountID = setting.kind, accepted(value, for: setting, known: known) == nil { continue }
            let target = store(setting)
            if target.object(forKey: setting.key) != nil {
                guard replace, differs(setting, from: value, known: known) else {
                    report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
                    continue
                }
                write(stored, for: setting)
                report.replaced.append(item)
                continue
            }
            write(stored, for: setting)
            report.added.append(item)
        }
        return report
    }

    private func write(_ stored: Stored, for setting: Setting) {
        let target = store(setting)
        switch stored {
        case .bool(let flag): target.set(flag, forKey: setting.key)
        case .text(let text): target.set(text, forKey: setting.key)
        }
    }
}
