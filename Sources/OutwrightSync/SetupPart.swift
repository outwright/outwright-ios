// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation
public import OutwrightSetup

/// One piece of the owner's setup that a setup file carries (accounts, subscribed calendars,
/// keys), under a name of its own and as its own versioned JSON. A build registers its
/// parts; the exchange walks them and never names one.
public protocol SetupPart: Sendable {
    /// The part's name in the file; stable across versions.
    var name: String { get }
    /// The part's name for the owner, in the device's language: written into the file beside its
    /// version, so a build without the part can still say what it leaves out.
    var title: String { get }
    /// The version of the JSON this part writes, and the newest it reads.
    var version: Int { get }
    /// The part's JSON, from what this device holds.
    func export() async throws(SetupError) -> Data
    /// What a part's JSON holds, for the confirmation screen. The content is hostile.
    func summary(of content: Data) throws(SetupError) -> [SetupItem]
    /// What `export` would carry from this device, read without a secret (nothing from the
    /// keychain), so it can be shown before the owner unlocks.
    func items() async -> [SetupItem]
    /// Adds what the content holds and this device does not have. The content is hostile; an item
    /// that cannot be added is reported, never a trap.
    func importContent(_ content: Data, version: Int) async -> SetupImportReport
    /// What the content holds that this device already has otherwise (a password, a current key),
    /// for the owner to choose between. Read with this device's secrets, after the file
    /// was opened; a difference names only what it is about, never a secret. The content is hostile:
    /// what cannot be read gives none.
    func differences(in content: Data) async -> [SetupDifference]
    /// `importContent` with the owner's choices: what `replacing` names (the ids of this part's
    /// differences) is taken from the file instead of kept, and nothing of an account in
    /// `leavingOff` is added. With no choices, it is `importContent` exactly.
    func importContent(_ content: Data, version: Int, choices: SetupChoices) async -> SetupImportReport
}

extension SetupPart {
    /// A part with nothing on the device to differ from has no differences.
    public func differences(in content: Data) async -> [SetupDifference] { [] }

    /// A part without differences or accounts has nothing to choose.
    public func importContent(_ content: Data, version: Int, choices: SetupChoices) async -> SetupImportReport {
        await importContent(content, version: version)
    }

    /// `importContent` taking `replacing` from the file and leaving nothing off.
    public func importContent(_ content: Data, version: Int, replacing: Set<String>) async -> SetupImportReport {
        await importContent(content, version: version, choices: SetupChoices(replacing: replacing))
    }
}

/// Something a setup file holds that the device already has otherwise: the owner chooses the
/// file's or keeps the device's. What the owner sees carries no secret.
public struct SetupDifference: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        /// An account's password or refresh token: its label is the address.
        case accountSecret
        /// An address's current own key: its label is the address.
        case ownKey
        /// An account's signature, written by the owner on both devices: its label is the address.
        case signature
        /// An account's servers and user name: its label is the address.
        case servers
    }

    public var kind: Kind
    /// The name of the part it belongs to.
    public var part: String
    /// What the owner sees: an address.
    public var label: String
    /// Stable within the part, and what the part is handed back when the owner takes the file's.
    public var id: String
    /// Both sides as they are now, digested (`state(here:file:)`): the same while neither side
    /// changes, so a kept answer is remembered by it. Never shown, logged or kept outside the
    /// keychain: for a password it is derived from secrets.
    public var state: String

    public init(kind: Kind, part: String, label: String, id: String, state: String = "") {
        self.kind = kind
        self.part = part
        self.label = label
        self.id = id
        self.state = state
    }

    /// The state of a difference between `here` and `file`: SHA-256, in hex, of both joined by NUL.
    public static func state(here: String, file: String) -> String {
        SHA256.hash(data: Data((here + "\u{0}" + file).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One thing a setup file holds, as the owner sees it.
public struct SetupItem: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case account, calendar, ownKey, contactKey
        /// The settings of one address (OpenPGP's switch and defaults): its label is the address.
        case addressSettings
        /// A whole part this build cannot read: its label is the part's title.
        case part
    }

    public var kind: Kind
    public var label: String

    public init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }
}

/// Why an item was not added.
public enum SkipReason: String, Sendable, Equatable, Hashable {
    /// The device already has it (the same address, the same calendar).
    case alreadyHere
    /// This build does not carry what it needs (a provider, a part), or the part is newer than it reads.
    case notInThisBuild
    /// Adding it failed; nothing of it was kept.
    case failed
    /// The owner left the account off this device.
    case leftOff
}

/// An item that was not added, and why.
public struct SetupSkip: Sendable, Equatable {
    public var item: SetupItem
    public var reason: SkipReason

    public init(item: SetupItem, reason: SkipReason) {
        self.item = item
        self.reason = reason
    }
}

/// What an import did.
public struct SetupImportReport: Sendable, Equatable {
    public var added: [SetupItem]
    public var skipped: [SetupSkip]
    /// Added, but the owner signs in again: its password or token could not come along.
    public var signInAgain: [SetupItem]
    /// Added, but its Notifications switch was on and could not be set: the owner turns it on.
    public var notificationsOff: [SetupItem]
    /// Already on the device without its secret (a password, a token, a key, an address), as after
    /// restoring the phone from an iCloud or Finder backup: the secret was filled in from the file,
    /// nothing else about it changed.
    public var restored: [SetupItem]
    /// Added with saving its contacts to the phone on, which the owner did not allow: turned off.
    public var phoneContactsOff: [SetupItem]
    /// Already on the device otherwise, and the owner chose the file's: replaced from the file
    /// (an account's secret, a current key), nothing else about it changed.
    public var replaced: [SetupItem]

    public init(
        added: [SetupItem] = [], skipped: [SetupSkip] = [], signInAgain: [SetupItem] = [],
        notificationsOff: [SetupItem] = [], restored: [SetupItem] = [], phoneContactsOff: [SetupItem] = [],
        replaced: [SetupItem] = []
    ) {
        self.added = added
        self.skipped = skipped
        self.signInAgain = signInAgain
        self.notificationsOff = notificationsOff
        self.restored = restored
        self.phoneContactsOff = phoneContactsOff
        self.replaced = replaced
    }

    /// A report of a whole part this build does not read, by its title.
    public static func notRead(_ title: String) -> SetupImportReport {
        SetupImportReport(skipped: [SetupSkip(item: SetupItem(kind: .part, label: title), reason: .notInThisBuild)])
    }

    /// A report of a whole part whose content could not be read, by its title.
    public static func unreadable(_ title: String) -> SetupImportReport {
        SetupImportReport(skipped: [SetupSkip(item: SetupItem(kind: .part, label: title), reason: .failed)])
    }

    /// Whether anything on the device changed: added, a secret filled in, or replaced from the file.
    public var changedAnything: Bool { !added.isEmpty || !restored.isEmpty || !replaced.isEmpty }

    mutating func merge(_ other: SetupImportReport) {
        added += other.added
        skipped += other.skipped
        signInAgain += other.signInAgain
        notificationsOff += other.notificationsOff
        restored += other.restored
        phoneContactsOff += other.phoneContactsOff
        replaced += other.replaced
    }
}

/// Reading and writing a part's JSON, with the cap every part shares.
enum SetupJSON {
    /// The most items one part holds.
    static let maxItems = 1_024
    /// The longest secret (password, token, address) a part carries.
    static let maxSecretLength = 16 * 1_024

    static func encode(_ value: some Encodable) throws(SetupError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) } catch { throw .malformed }
    }

    static func decode<T: Decodable>(_ type: T.Type, from content: Data) throws(SetupError) -> T {
        guard content.count <= SetupBundle.maxPartSize else { throw .tooLarge }
        do { return try JSONDecoder().decode(type, from: content) } catch { throw .malformed }
    }
}
