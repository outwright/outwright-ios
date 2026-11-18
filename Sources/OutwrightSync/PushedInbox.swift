// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightStore

/// What a push does on the phone: finds the account the push's subscription belongs to, fetches
/// that account's Inbox into the store (nothing else: no other folder or account, nothing queued
/// sent), and claims the unread mail that came above the account's push mark. Run by the
/// notification extension; never decrypts, so a protected message stays protected.
public struct PushedInbox: Sendable {
    private let store: MailStore
    private let credentials: CredentialProvider
    private let now: @Sendable () -> Date
    private let account: @Sendable (String) -> Account?

    /// `account` maps a subscription id to its account; nil for one no longer known.
    public init(
        store: MailStore, credentials: CredentialProvider, now: @escaping @Sendable () -> Date = { Date() },
        account: @escaping @Sendable (String) -> Account?
    ) {
        self.store = store
        self.credentials = credentials
        self.now = now
        self.account = account
    }

    /// Never throws: whatever fails, or the budget running out, answers no rows and why. Running
    /// out leaves the fetch to end on its own and closes its connection.
    public func update(subscriptionID: String, budget: Duration) async -> (rows: [MessageRow], why: ProbeWhy) {
        guard let account = account(subscriptionID) else {
            return ([], .unknownSubscription)
        }
        do {
            try store.markPushedInboxIfNew(account.id, now: now())
        } catch {
            return ([], .serverFailed)
        }
        let syncer = AccountSyncer(account: account, store: store, credentials: credentials, now: now)
        let outcome = FirstAnswer()
        let work = Task {
            do throws(SyncError) {
                try await syncer.fetchInbox()
                await outcome.finish(nil)
            } catch {
                await outcome.finish(Self.why(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: budget)
            await outcome.finish(.outOfTime)
        }
        let failure = await outcome.value()
        timer.cancel()
        if let failure {
            work.cancel()
            // A server that stopped answering is not waited for.
            Task { await syncer.disconnect() }
            return ([], failure)
        }
        await syncer.disconnect()
        guard let rows = try? store.claimPushedInboxMail(account.id, now: now()) else {
            return ([], .serverFailed)
        }
        return (rows, rows.isEmpty ? .nothingNew : .found)
    }

    /// Signing in (credentials, refusal, no way through to the server) or the server after it.
    static func why(_ error: SyncError) -> ProbeWhy {
        switch error {
        case .imap(.authenticationFailed), .imap(.net), .noPassword, .keychain, .needsSignIn, .oauth,
            .noTokenSignIn:
            .signInFailed
        default:
            .serverFailed
        }
    }
}

/// The first answer of the fetch or the timer; nil is a fetch that succeeded.
private actor FirstAnswer {
    private var answer: ProbeWhy??
    private var waiters: [CheckedContinuation<ProbeWhy?, Never>] = []

    func finish(_ value: ProbeWhy?) {
        guard answer == nil else {
            return
        }
        answer = .some(value)
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> ProbeWhy? {
        if let answer {
            return answer
        }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
