// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
public import OutwrightPush
public import OutwrightStore
public import OutwrightSync

/// Switching push on and off for an account: `PushController`, or a stand-in in tests.
public protocol PushSwitching: Sendable {
    func isEnabled(_ account: AccountID) async -> Bool
    func enable(_ account: Account) async throws(PushError)
    func disable(_ account: AccountID) async throws(PushError)
    /// The account was changed in the app: push's copy of it (the notification extension's) follows.
    func accountChanged(_ account: Account) async
}

extension PushController: PushSwitching {}

/// What the app gives settings for push: the switch, whether a push method offers push for an account,
/// asking for permission to notify, and registering for remote notifications. A host that
/// answers is remembered for the session; one that does not is asked again next time.
@MainActor
public final class PushSupport {
    let switcher: any PushSwitching
    private let offersPush: @Sendable (Account) async -> Bool
    let askPermission: @Sendable () async -> Bool
    let registerForRemote: @MainActor () -> Void
    let setupGuide: @Sendable (Account) async -> URL?
    private var answers: [AccountID: Task<Bool, Never>] = [:]

    public init(
        switcher: any PushSwitching, offersPush: @escaping @Sendable (Account) async -> Bool,
        askPermission: @escaping @Sendable () async -> Bool, registerForRemote: @escaping @MainActor () -> Void,
        setupGuide: @escaping @Sendable (Account) async -> URL? = { _ in nil }
    ) {
        self.switcher = switcher
        self.offersPush = offersPush
        self.askPermission = askPermission
        self.registerForRemote = registerForRemote
        self.setupGuide = setupGuide
    }

    func isAvailable(_ account: Account) async -> Bool {
        if let known = answers[account.id] {
            return await known.value
        }
        let check = offersPush
        // Detached: the check is network work and never runs on the main actor.
        let task = Task.detached { await check(account) }
        answers[account.id] = task
        let answer = await task.value
        if !answer {
            // Only a yes is kept: a failure is asked again the next time.
            answers[account.id] = nil
        }
        return answer
    }
}

/// Why the Notifications switch did not stay where it was put.
public enum NotificationsMessage: Sendable, Equatable {
    /// The owner has not let Outwright notify.
    case permissionDenied
    /// Push is on for as many mailboxes as the relay takes.
    case limit
    /// Switching on failed for another reason, or switching off did not reach the servers.
    case failed
    /// Local notices could not be switched on the phone.
    case notChanged
    /// The mail server refused to set up push.
    case serverRefused
    /// The mail server is not set up for push; `guide` says how its owner sets it up.
    case notSetUp(guide: URL?)
}

/// Local new-mail notices, as the switch sees them: the store, or a stand-in in tests.
public protocol LocalNotifying: Sendable {
    func isOn(_ account: AccountID) async -> Bool
    func set(_ wanted: Bool, for account: AccountID) async throws(StoreError)
    /// Asks the owner for permission to notify (once; later calls answer as before).
    func askPermission() async -> Bool
}

/// Local notices kept in the store.
public struct StoreLocalNotifying: LocalNotifying {
    let store: MailStore
    let permission: @Sendable () async -> Bool

    public init(store: MailStore, askPermission: @escaping @Sendable () async -> Bool) {
        self.store = store
        self.permission = askPermission
    }

    public func isOn(_ account: AccountID) async -> Bool {
        (try? store.notifiesNewMail(account)) ?? false
    }

    public func set(_ wanted: Bool, for account: AccountID) async throws(StoreError) {
        try store.setNotifiesNewMail(wanted, for: account)
    }

    public func askPermission() async -> Bool {
        await permission()
    }
}

/// The Notifications switch of one account, shown for every account: push where the account's host
/// offers push, the build has push and push is included, local notices after a background refresh
/// otherwise.
@Observable @MainActor
public final class NotificationsToggleModel {
    public private(set) var isOn = false
    /// On through local notices rather than push.
    public private(set) var isLocal = false
    public private(set) var isWorking = false
    public private(set) var message: NotificationsMessage?

    @ObservationIgnored private let account: Account
    @ObservationIgnored private let support: PushSupport?
    @ObservationIgnored private let local: any LocalNotifying
    /// Push is included for this user (`Offering`); without it, on is local notices only.
    public let pushIncluded: Bool

    public init(account: Account, support: PushSupport?, local: any LocalNotifying, pushIncluded: Bool = true) {
        self.account = account
        self.support = support
        self.local = local
        self.pushIncluded = pushIncluded
    }

    public func load() async {
        await settle()
    }

    /// On asks for permission to notify, then switches push on where it can, local notices
    /// otherwise; any refusal leaves it off with a message. Off switches off whichever is on.
    public func set(_ wanted: Bool) async {
        guard !isWorking, wanted != isOn else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        if wanted {
            await switchOn()
        } else {
            await switchOff()
        }
        await settle()
    }

    private func switchOn() async {
        isOn = true
        let allowed: Bool
        if let support {
            allowed = await support.askPermission()
        } else {
            allowed = await local.askPermission()
        }
        guard allowed else {
            isOn = false
            message = .permissionDenied
            return
        }
        if pushIncluded, let support, await support.isAvailable(account) {
            support.registerForRemote()
            do {
                try await support.switcher.enable(account)
            } catch {
                message = await Self.message(for: error, account: account, support: support)
            }
        } else {
            do {
                try await local.set(true, for: account.id)
            } catch {
                message = .notChanged
            }
        }
    }

    private static func message(
        for error: PushError, account: Account, support: PushSupport
    ) async -> NotificationsMessage {
        switch error {
        case .limit: .limit
        case .serverRefused: .serverRefused
        case .notSetUp: .notSetUp(guide: await support.setupGuide(account))
        default: .failed
        }
    }

    private func switchOff() async {
        isOn = false
        if let support, await support.switcher.isEnabled(account.id) {
            // Off whatever the servers answer: the phone forgets the subscription either way.
            do {
                try await support.switcher.disable(account.id)
            } catch {
                message = .failed
            }
        }
        if await local.isOn(account.id) {
            do {
                try await local.set(false, for: account.id)
            } catch {
                message = .notChanged
            }
        }
    }

    private func settle() async {
        var pushed = false
        if let support { pushed = await support.switcher.isEnabled(account.id) }
        let locally = await local.isOn(account.id)
        isOn = pushed || locally
        isLocal = !pushed && locally
    }
}
