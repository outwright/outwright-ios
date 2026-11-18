// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightPush
import Synchronization

/// One account with push switched on. No secret: the notification extension reads the
/// account's endpoints from it, and its keys and password from the keychain.
public struct PushRegistration: Codable, Sendable {
    public var account: Account
    public var relay: RelaySubscription
    /// The method the server side was made with.
    public var method: PushMethodKind
    /// The method's handle for the server side (a JMAP subscription id, a METADATA entry).
    public var handle: String
    /// For an addressed method, the address its sender posts to.
    public var address: URL?

    public init(
        account: Account, relay: RelaySubscription, method: PushMethodKind, handle: String, address: URL? = nil
    ) {
        self.account = account
        self.relay = relay
        self.method = method
        self.handle = handle
        self.address = address
    }

    private enum CodingKeys: String, CodingKey {
        case account, relay, method, handle, address
        /// What a registry written before push methods called the handle; those were all JMAP.
        case jmapID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(Account.self, forKey: .account)
        relay = try container.decode(RelaySubscription.self, forKey: .relay)
        if let method = try container.decodeIfPresent(PushMethodKind.self, forKey: .method) {
            self.method = method
            handle = try container.decode(String.self, forKey: .handle)
        } else {
            method = .jmap
            handle = try container.decode(String.self, forKey: .jmapID)
        }
        address = try container.decodeIfPresent(URL.self, forKey: .address)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(relay, forKey: .relay)
        try container.encode(method, forKey: .method)
        try container.encode(handle, forKey: .handle)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

/// An address handed out for an account and not yet checked: its relay subscription is pending.
/// Kept in the vault until the check passes, the address is removed or the account goes.
public struct PushIssued: Codable, Sendable {
    public var account: Account
    public var relay: RelaySubscription
    public var method: PushMethodKind
    public var address: PushAddress
}

/// The relay device and the APNs token it was last given. Kept only in the vault.
struct PushDeviceRecord: Codable, Sendable {
    var device: RelayDevice
    var token: Data
}

/// The accounts with push on, as JSON in the app group (shared with the notification
/// extension), and their secrets in a `PushVault`: the relay device secret and each
/// subscription's Web Push keys never reach the file. A file that will not read (garbage,
/// over 1 MiB) counts as empty.
public final class PushRegistry: Sendable {
    static let maxFileSize = 1 << 20
    static let deviceKey = "device"

    private let fileURL: URL
    private let vault: any PushVault
    private let lock = Mutex(())

    public init(fileURL: URL, vault: any PushVault) {
        self.fileURL = fileURL
        self.vault = vault
    }

    public func registration(for account: AccountID) -> PushRegistration? {
        registrations().first { $0.account.id == account }
    }

    public func registration(subscriptionID: String) -> PushRegistration? {
        (try? coordinated(writing: false) { $0[subscriptionID] }) ?? nil
    }

    /// Every registration, in no particular order.
    public func registrations() -> [PushRegistration] {
        (try? coordinated(writing: false) { Array($0.values) }) ?? []
    }

    /// The subscription's Web Push keys; nil when there are none, a throw when they will not read.
    public func keys(subscriptionID: String) throws(SyncError) -> WebPushKeys? {
        guard let raw = try vault.data(for: Self.keysKey(subscriptionID)) else {
            return nil
        }
        do {
            return try WebPushKeys(rawRepresentation: raw)
        } catch {
            throw .store("The push keys could not be read")
        }
    }

    /// A method's secret for the subscription (JMAP's Web Push keys), removed with it.
    func setSecret(_ secret: Data, subscriptionID: String) throws(SyncError) {
        try vault.set(secret, for: Self.keysKey(subscriptionID))
    }

    /// Every registration of `account` takes it as given; the subscription stays as it was.
    func update(_ account: Account) throws(SyncError) {
        try coordinated(writing: true) { registrations in
            for (id, registration) in registrations where registration.account.id == account.id {
                registrations[id]?.account = account
            }
        }
    }

    func save(_ registration: PushRegistration) throws(SyncError) {
        try coordinated(writing: true) { $0[registration.relay.id] = registration }
    }

    /// Removes the subscription's keys, then its registration: a file that will not write
    /// leaves no keys behind.
    func remove(subscriptionID: String) throws(SyncError) {
        try vault.remove(Self.keysKey(subscriptionID))
        try coordinated(writing: true) { $0[subscriptionID] = nil }
    }

    /// The address issued for the account and not yet checked.
    func issued(for account: AccountID) -> PushIssued? {
        guard let data = try? vault.data(for: Self.issuedKey(account)) else {
            return nil
        }
        return try? JSONDecoder().decode(PushIssued.self, from: data)
    }

    func saveIssued(_ issued: PushIssued) throws(SyncError) {
        guard let data = try? JSONEncoder().encode(issued) else {
            throw .store("The push address could not be written")
        }
        try vault.set(data, for: Self.issuedKey(issued.account.id))
    }

    func removeIssued(for account: AccountID) throws(SyncError) {
        try vault.remove(Self.issuedKey(account))
    }

    /// Whether the account's address was dropped since it was last handed out (its channel or
    /// subscription is gone): the settings say so.
    func isDropped(_ account: AccountID) -> Bool {
        ((try? vault.data(for: Self.droppedKey(account))) ?? nil) != nil
    }

    func setDropped(_ dropped: Bool, for account: AccountID) throws(SyncError) {
        if dropped {
            try vault.set(Data([1]), for: Self.droppedKey(account))
        } else {
            try vault.remove(Self.droppedKey(account))
        }
    }

    private static func droppedKey(_ account: AccountID) -> String {
        "dropped.\(account.raw.uuidString)"
    }

    private static func issuedKey(_ account: AccountID) -> String {
        "issued.\(account.raw.uuidString)"
    }

    func device() throws(SyncError) -> PushDeviceRecord? {
        guard let data = try vault.data(for: Self.deviceKey) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(PushDeviceRecord.self, from: data) else {
            throw .store("The push device could not be read")
        }
        return record
    }

    func forgetDevice() throws(SyncError) {
        try vault.remove(Self.deviceKey)
    }

    func setDevice(_ record: PushDeviceRecord) throws(SyncError) {
        guard let data = try? JSONEncoder().encode(record) else {
            throw .store("The push device could not be written")
        }
        try vault.set(data, for: Self.deviceKey)
    }

    private static func keysKey(_ subscriptionID: String) -> String {
        "keys.\(subscriptionID)"
    }

    // MARK: - File

    private func coordinated<T: Sendable>(
        writing: Bool, _ body: (inout [String: PushRegistration]) -> T
    ) throws(SyncError) -> T {
        let result = lock.withLock { _ in
            Result { () throws(SyncError) -> T in try coordinate(writing: writing, body) }
        }
        return try result.get()
    }

    private func coordinate<T: Sendable>(
        writing: Bool, _ body: (inout [String: PushRegistration]) -> T
    ) throws(SyncError) -> T {
        var outcome: Result<T, SyncError> = .failure(.store("The push registry was not reached"))
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
                outcome = Self.readModifyWrite(url, body)
            }
        } else {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
                var entries = Self.read(url)
                outcome = .success(body(&entries))
            }
        }
        if coordinationError != nil {
            throw .store("The push registry could not be opened")
        }
        return try outcome.get()
    }

    private static func readModifyWrite<T>(
        _ url: URL, _ body: (inout [String: PushRegistration]) -> T
    ) -> Result<T, SyncError> {
        var entries = read(url)
        let value = body(&entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries), data.count <= maxFileSize else {
            return .failure(.store("The push registry is too large"))
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return .failure(.store("The push registry could not be written"))
        }
        return .success(value)
    }

    private static func read(_ url: URL) -> [String: PushRegistration] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: PushRegistration].self, from: data)) ?? [:]
    }
}
