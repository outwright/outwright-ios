// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import OutwrightNet
public import OutwrightSetup
public import OutwrightStore

/// The accounts, each with its password or OAuth refresh token. A refresh token records the
/// client id it was issued to: a build that signs in with another one drops it and asks the owner
/// to sign in again. A refresh token rotates on renewal, so another one here than the file's tells
/// nothing: an OAuth account differs only when this device's sign-in does not work.
public struct AccountsSetupPart: SetupPart {
    public static let partName = "accounts"
    public let name = AccountsSetupPart.partName
    public let version = 1
    public let title: String

    let store: MailStore
    let secrets: any SecretStore
    let providers: ProviderSet
    /// Whether push is switched on for an account on this device; the store holds only local notices.
    let pushEnabled: @Sendable (AccountID) async -> Bool
    /// What the account's sync last failed with on this device; nil when it last worked.
    let lastError: @Sendable (AccountID) async -> SyncError?

    public init(
        store: MailStore, secrets: any SecretStore, providers: ProviderSet,
        pushEnabled: @escaping @Sendable (AccountID) async -> Bool = { _ in false },
        lastError: @escaping @Sendable (AccountID) async -> SyncError? = { _ in nil },
        title: String = "Accounts"
    ) {
        self.title = title
        self.store = store
        self.secrets = secrets
        self.providers = providers
        self.pushEnabled = pushEnabled
        self.lastError = lastError
    }

    /// The part's JSON, version 1.
    struct Content: Codable {
        var accounts: [AccountEntry]
    }

    public func export() async throws(SetupError) -> Data {
        let held: [Account]
        do { held = try store.accounts() } catch { throw .unavailable }
        var entries: [AccountEntry] = []
        for account in held {
            var entry = AccountEntry(account: account)
            // The owner's Notifications switch: on through push or through local notices.
            let local = (try? store.notifiesNewMail(account.id)) ?? false
            entry.notifies = local ? true : await pushEnabled(account.id)
            do {
                switch account.auth {
                case .password:
                    entry.password = try secrets.password(for: account.id)?.reveal()
                case .oauth:
                    entry.refreshToken = try secrets.refreshToken(for: account.id)?.reveal()
                    entry.clientID = entry.refreshToken == nil ? nil : providers.oauthClientIDs[account.provider]
                }
            } catch {
                throw .unavailable
            }
            entries.append(entry)
        }
        return try SetupJSON.encode(Content(accounts: entries))
    }

    public func summary(of content: Data) throws(SetupError) -> [SetupItem] {
        try read(content).map { Self.item($0.account) }
    }

    public func items() async -> [SetupItem] {
        ((try? store.accounts()) ?? []).map(Self.item)
    }

    /// An account here (by its address) whose password differs from the file's, or whose sign-in is
    /// refused while the file has a refresh token this build can use. Its id is the address,
    /// lower-cased.
    public func differences(in content: Data) async -> [SetupDifference] {
        guard let entries = try? read(content), let held = try? store.accounts() else { return [] }
        let byAddress = Self.byAddress(held)
        var seen = Set<String>()
        var differences: [SetupDifference] = []
        for entry in entries {
            let address = entry.account.email.lowercased()
            guard !seen.contains(address), let here = byAddress[address],
                await replacement(for: here, from: entry) != nil
            else { continue }
            seen.insert(address)
            differences.append(
                SetupDifference(kind: .accountSecret, part: name, label: entry.account.email, id: address))
        }
        return differences
    }

    public func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        await importContent(content, version: version, replacing: [])
    }

    /// Adds what the content holds and this device does not have; an account here whose address
    /// is in `replacing` takes the file's secret, and nothing else of it changes.
    public func importContent(_ content: Data, version: Int, replacing: Set<String>) async -> SetupImportReport {
        guard version <= self.version else { return .notRead(title) }
        guard let entries = try? read(content), let held = try? store.accounts() else { return .unreadable(title) }
        var addresses = Set(held.map { $0.email.lowercased() })
        var ids = Set(held.map(\.id))
        let byID = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byAddress = Self.byAddress(held)
        var replaced = Set<String>()
        var placedAfter = held
        var report = SetupImportReport()
        for entry in entries {
            let item = Self.item(entry.account)
            let address = entry.account.email.lowercased()
            if replacing.contains(address), !replaced.contains(address),
                await replaceSecret(of: byAddress[address], from: entry, item: item, into: &report) {
                replaced.insert(address)
                continue
            }
            if let here = byID[entry.account.id] {
                fillSecret(of: here, from: entry, item: item, into: &report)
                continue
            }
            guard !addresses.contains(address), !ids.contains(entry.account.id) else {
                report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
                continue
            }
            guard providers.ids.contains(entry.account.provider) else {
                report.skipped.append(SetupSkip(item: item, reason: .notInThisBuild))
                continue
            }
            // On a device with accounts of its own, the restored ones go after them, in their order.
            var account = entry.account
            if !held.isEmpty { account.sortOrder = account.placed(after: placedAfter, colors: 1).sortOrder }
            guard let signInAgain = add(account, from: entry) else {
                report.skipped.append(SetupSkip(item: item, reason: .failed))
                continue
            }
            addresses.insert(address)
            ids.insert(account.id)
            placedAfter.append(account)
            report.added.append(item)
            restoreNotifications(entry, for: account, item: item, into: &report)
            if signInAgain { report.signInAgain.append(item) }
        }
        return report
    }

    /// Saves the account with the secret that came along. Nil when it could not be added (nothing
    /// of it is kept); otherwise whether the owner signs in again.
    private func add(_ account: Account, from entry: AccountEntry) -> Bool? {
        let secret: String?
        do {
            secret = try usableSecret(entry)
            try store.save(account)
        } catch {
            return nil
        }
        return finish(account, secret: secret)
    }

    /// Fills in the secret of an account already here, and reports what became of it.
    private func fillSecret(
        of here: Account, from entry: AccountEntry, item: SetupItem, into report: inout SetupImportReport
    ) {
        switch fillSecret(of: here, from: entry) {
        case true?: report.restored.append(item)
        case false?: report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
        case nil: report.skipped.append(SetupSkip(item: item, reason: .failed))
        }
    }

    /// The account is here (its id matches, as after restoring the phone from an iCloud or Finder
    /// backup, whose keychain stays behind): its secret is filled in when it has none, and nothing
    /// else about it changes. True when filled in, false when there was nothing to fill (it has
    /// one, or the file's cannot be used here), nil when the secret store refused it.
    private func fillSecret(of here: Account, from entry: AccountEntry) -> Bool? {
        guard here.auth == entry.account.auth, here.provider == entry.account.provider else { return false }
        let held: Secret?
        do {
            held = try heldSecret(of: here)
        } catch {
            // Whether it has one is not known: it is left as it is.
            return false
        }
        guard held == nil, let secret = (try? usableSecret(entry)) ?? nil else { return false }
        return keep(secret, for: here) ? true : nil
    }

    /// Takes the file's secret for the account here, when it is a difference, and reports it;
    /// false when there was none to take.
    private func replaceSecret(
        of here: Account?, from entry: AccountEntry, item: SetupItem, into report: inout SetupImportReport
    ) async -> Bool {
        guard let here, let secret = await replacement(for: here, from: entry) else { return false }
        if keep(secret, for: here) {
            report.replaced.append(item)
        } else {
            report.skipped.append(SetupSkip(item: item, reason: .failed))
        }
        return true
    }

    /// The file's secret for an account here, when the owner may take it instead of the device's:
    /// the same kind of account with a provider in this build, a secret this build can use (a
    /// token for another client id is none), and the device's own secret there and not working: a
    /// password that differs, or a refresh token whose sign-in is refused (another token alone
    /// tells nothing, as it rotates on renewal). A device without one has it filled in, never
    /// asked; nil otherwise.
    private func replacement(for here: Account, from entry: AccountEntry) async -> String? {
        guard here.auth == entry.account.auth, here.provider == entry.account.provider,
            providers.ids.contains(here.provider),
            let secret = (try? usableSecret(entry)) ?? nil,
            let held = (try? heldSecret(of: here)) ?? nil,
            held.reveal() != secret
        else { return nil }
        switch here.auth {
        case .password: return secret
        case .oauth: return await lastError(here.id)?.refusesSignIn == true ? secret : nil
        }
    }

    /// The account's password or refresh token on this device.
    private func heldSecret(of account: Account) throws(SyncError) -> Secret? {
        switch account.auth {
        case .password: try secrets.password(for: account.id)
        case .oauth: try secrets.refreshToken(for: account.id)
        }
    }

    /// The device's accounts by their address, lower-cased; the first of two with one address.
    private static func byAddress(_ accounts: [Account]) -> [String: Account] {
        Dictionary(accounts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The switch comes along as local notices: push is set up on this device by its own switch,
    /// which needs the server and the owner's permission.
    /// An account whose switch was on and could not be set is reported, still added.
    private func restoreNotifications(
        _ entry: AccountEntry, for account: Account, item: SetupItem, into report: inout SetupImportReport
    ) {
        guard entry.notifies == true else { return }
        do {
            try store.setNotifiesNewMail(true, for: account.id)
        } catch {
            report.notificationsOff.append(item)
        }
    }

    /// The secret this build keeps for the account: nil when none it can use came along (the owner
    /// signs in again). Throws for an entry not to be added.
    private func usableSecret(_ entry: AccountEntry) throws(SetupError) -> String? {
        let secret: String?
        switch entry.account.auth {
        case .password:
            secret = entry.password
        case .oauth:
            let ours = providers.oauthClientIDs[entry.account.provider]
            secret = ours != nil && entry.clientID == ours ? entry.refreshToken : nil
        }
        guard !entry.account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (secret?.utf8.count ?? 0) <= SetupJSON.maxSecretLength
        else { throw .malformed }
        guard let secret, !secret.isEmpty else { return nil }
        return secret
    }

    /// Keeps the saved account's secret. Nil when the secret store refused it and the account was
    /// removed again; otherwise whether the owner signs in again (no secret, or the account could
    /// not be removed and stays without one).
    private func finish(_ account: Account, secret: String?) -> Bool? {
        guard let secret else { return true }
        guard !keep(secret, for: account) else { return false }
        try? secrets.remove(for: account.id)
        do {
            try store.removeAccount(account.id)
            return nil
        } catch {
            return true
        }
    }

    /// Keeps the account's secret in the secret store; false when the store refused it.
    private func keep(_ secret: String, for account: Account) -> Bool {
        do {
            switch account.auth {
            case .password: try secrets.setPassword(Secret(secret), for: account.id)
            case .oauth: try secrets.setRefreshToken(Secret(secret), for: account.id)
            }
            return true
        } catch {
            return false
        }
    }

    private func read(_ content: Data) throws(SetupError) -> [AccountEntry] {
        let entries = try SetupJSON.decode(Content.self, from: content).accounts
        guard entries.count <= SetupJSON.maxItems else { throw .tooLarge }
        return entries
    }

    private static func item(_ account: Account) -> SetupItem {
        SetupItem(kind: .account, label: account.email)
    }
}

/// One account in the accounts part.
struct AccountEntry: Codable {
    /// As `Account` encodes, its id kept.
    var account: Account
    var password: String?
    var refreshToken: String?
    /// The client id the refresh token was issued to.
    var clientID: String?
    /// The account's Notifications switch was on.
    var notifies: Bool?
}
