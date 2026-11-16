// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightPush
import OutwrightStore
import OutwrightSync
import Synchronization

@testable import OutwrightUI

/// Push as the switch sees it, without a relay: what `enable` answers is set by the test.
final class FakeSwitch: PushSwitching, Sendable {
    private let state = Mutex<(on: Set<AccountID>, enabled: [AccountID], failure: PushError?)>(([], [], nil))
    private let disableFailure: PushError?
    /// Run as `disable` starts, before the account is forgotten.
    private let onDisable: @Sendable (AccountID) async -> Void

    init(
        failure: PushError? = nil, disableFailure: PushError? = nil,
        onDisable: @escaping @Sendable (AccountID) async -> Void = { _ in }
    ) {
        self.disableFailure = disableFailure
        self.onDisable = onDisable
        state.withLock { $0.failure = failure }
    }

    var enabled: [AccountID] { state.withLock { $0.enabled } }

    func isEnabled(_ account: AccountID) async -> Bool {
        state.withLock { $0.on.contains(account) }
    }

    func enable(_ account: Account) async throws(PushError) {
        let failure = state.withLock { state -> PushError? in
            state.enabled.append(account.id)
            if state.failure == nil { state.on.insert(account.id) }
            return state.failure
        }
        if let failure { throw failure }
    }

    func accountChanged(_ account: Account) async {}

    /// Forgets the account even when it then throws, as `PushController` does.
    func disable(_ account: AccountID) async throws(PushError) {
        await onDisable(account)
        _ = state.withLock { $0.on.remove(account) }
        if let disableFailure { throw disableFailure }
    }
}

/// Local notices without a store: which accounts have them on, and the answer to the permission.
final class FakeLocal: LocalNotifying, Sendable {
    private let on = Mutex<Set<AccountID>>([])
    private let permission: Bool
    private let fails: Bool

    init(permission: Bool = true, fails: Bool = false) {
        self.permission = permission
        self.fails = fails
    }

    func isOn(_ account: AccountID) async -> Bool { on.withLock { $0.contains(account) } }
    func set(_ wanted: Bool, for account: AccountID) async throws(StoreError) {
        if fails { throw .noSuchFolder }
        on.withLock { _ = wanted ? $0.insert(account).inserted : ($0.remove(account) != nil) }
    }
    func askPermission() async -> Bool { permission }
}

func account() -> Account {
    let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
    return Account(
        id: AccountID(raw: UUID()), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
        imap: endpoint, smtp: endpoint, user: "anna@example.org", signature: "", sortOrder: 0)
}
