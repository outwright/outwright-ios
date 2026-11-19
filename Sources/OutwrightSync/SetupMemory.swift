// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightNet

/// What bringing a setup here remembers for the next time: the differences the owner kept this
/// device's for, by their state, so they are not asked again until either side changes; and the
/// accounts the owner left off this device. Kept in the keychain only: a state can be derived from
/// a password.
public struct SetupMemory: Codable, Sendable, Equatable {
    /// `<part>/<id>` of a difference to the state the owner kept this device's at.
    public var kept: [String: String]
    /// Addresses, lower-cased, of accounts not brought to this device.
    public var leftOff: Set<String>

    public init(kept: [String: String] = [:], leftOff: Set<String> = []) {
        self.kept = kept
        self.leftOff = leftOff
    }

    /// The most entries of either kind read: far more than anyone has accounts.
    static let maxEntries = 4_096

    /// The key a difference is remembered under.
    static func key(_ difference: SetupDifference) -> String { difference.part + "/" + difference.id }

    /// Whether the owner kept this device's for the difference as it is now.
    func isKept(_ difference: SetupDifference) -> Bool {
        !difference.state.isEmpty && kept[Self.key(difference)] == difference.state
    }

    /// What the keychain holds; empty when there is nothing, it cannot be read, or it is too large.
    public static func load(from secrets: any SecretStore) -> SetupMemory {
        stored(in: secrets) ?? SetupMemory()
    }

    /// What the keychain holds, empty when it holds nothing; nil when it holds something that cannot
    /// be read (the keychain refused, or it is out of shape or too large), which is then never
    /// written over.
    static func stored(in secrets: any SecretStore) -> SetupMemory? {
        let held: Secret?
        do { held = try secrets.setupMemory() } catch { return nil }
        guard let held else { return SetupMemory() }
        guard let memory = try? JSONDecoder().decode(SetupMemory.self, from: Data(held.reveal().utf8)),
            memory.kept.count <= maxEntries, memory.leftOff.count <= maxEntries
        else { return nil }
        return memory
    }

    public func save(to secrets: any SecretStore) throws(SyncError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(bytes: data, encoding: .utf8) else { return }
        try secrets.setSetupMemory(Secret(text))
    }
}

/// The owner's answers for one part on an import: the differences (by id) to take from the file,
/// and the accounts (by address, lower-cased) to leave off this device.
public struct SetupChoices: Sendable, Equatable {
    public var replacing: Set<String>
    public var leavingOff: Set<String>

    public init(replacing: Set<String> = [], leavingOff: Set<String> = []) {
        self.replacing = replacing
        self.leavingOff = leavingOff
    }

    public static let none = SetupChoices()
}
