// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightSync

/// The build's providers: what Add account offers, and who signs an account in again.
extension AppModel {
    /// How many colours accounts take in turn: a provider places a new account with it.
    public static var accountColors: Int { Theme.avatarColors.count }

    /// The registered providers that can add an account, with their sign-ins, in the
    /// composition's order.
    var addableProviders: [(provider: any AccountProvider, signIn: any ProviderSignIn)] {
        modules.providers.compactMap { provider in provider.signIn(app: self).map { (provider, $0) } }
    }

    /// The sign-in of the first provider in `entries` that claims `address`; nil when none
    /// does, or none has said so `within` the limit, and the owner's own server is looked up.
    static func signIn(
        claiming address: String, among entries: [(provider: any AccountProvider, signIn: any ProviderSignIn)],
        resolver: any DoHResolving, within limit: Duration = .seconds(3)
    ) async -> (any ProviderSignIn)? {
        let providers = entries.map(\.provider)
        let found = await withTaskGroup(of: Int?.self, returning: Int?.self) { group in
            group.addTask { await firstClaiming(address, among: providers, resolver: resolver) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let found, entries.indices.contains(found) else {
            return nil
        }
        return entries[found].signIn
    }

    /// Which of `providers` is the first to claim `address`.
    private static func firstClaiming(
        _ address: String, among providers: [any AccountProvider], resolver: any DoHResolving
    ) async -> Int? {
        var index = 0
        for provider in providers {
            if await provider.claims(address, resolver: resolver) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The account's provider is not in this build: it is kept, shown, and not synced.
    func isUnavailable(_ account: Account) -> Bool {
        account.provider != .ownServer && !modules.providers.contains { $0.id == account.provider }
    }

    /// The accounts mail, events and contacts can be written on: all but the unavailable ones,
    /// which this build never syncs.
    var writableAccounts: [Account] {
        accounts.filter { !isUnavailable($0) }
    }

    /// The account's provider's sign-in; nil for the owner's own server or a missing provider.
    func signIn(for account: Account) -> (any ProviderSignIn)? {
        modules.providers.first { $0.id == account.provider }?.signIn(app: self)
    }

    /// The account's provider, when this build carries it.
    func provider(of account: Account) -> (any AccountProvider)? {
        modules.providers.first { $0.id == account.provider }
    }

    /// The account's sign-in is gone and its provider can sign it in again.
    func needsSignInAgain(_ account: AccountID) -> Bool {
        guard let stored = accounts.first(where: { $0.id == account }), provider(of: stored) != nil else {
            return false
        }
        return syncProblems.contains { $0.id == account && $0.problem == .signInAgain }
    }
}
