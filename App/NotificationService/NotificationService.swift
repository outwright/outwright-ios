// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import OutwrightModel
import OutwrightPush
import OutwrightStore
import OutwrightSync
import Synchronization
import UserNotifications

/// Runs when a push comes: updates the Inbox of the account the push is for (the push carries only
/// the subscription id) in the store it shares with the app, and puts the sender and subject of
/// what came in place of the generic "New mail"; an encrypted message shows no subject. Whatever
/// goes wrong, the generic notification is delivered, in time.
final class NotificationService: UNNotificationServiceExtension {
    /// The update's time; iOS gives the extension about 30 s in all.
    static let budget = Duration.seconds(20)
    /// The original content goes out by then whatever the update is doing.
    static let deadline = Duration.seconds(25)
    static let maxSubscriptionID = 128

    private var delivery: Delivery?
    private var notes: PushNotes?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let original = request.content
        guard let id = original.userInfo["s"] as? String, !id.isEmpty, id.utf8.count <= Self.maxSubscriptionID,
            let container = PushPlaces.container
        else {
            contentHandler(original)
            return
        }
        StoreUse.begin()
        // Before the notification goes out, whichever path sends it: a fetch still running is
        // interrupted and lets go of the store the app shares.
        let delivery = Delivery(contentHandler, original: original) { StoreUse.end() }
        self.delivery = delivery
        let registry = PushRegistry(fileURL: PushPlaces.registry(in: container), vault: KeychainPushVault())
        let marks = PushWatermarks(fileURL: PushPlaces.watermarks(in: container))
        let credentials = CredentialProvider(
            secrets: KeychainSecretStore(), tokens: ExtensionComposition.tokenRenewals())
        // Beside the update, never before the notification: a push method's server side that lapses
        // unless renewed is moved on, at most every 12 hours.
        let renewal = ExtensionRenewal(
            registry: registry, relay: BuildSettings.main.relay.map { RelayClient(base: $0) },
            methods: ExtensionComposition.pushMethods(credentials: credentials), marks: marks)
        Task { await renewal.renewIfDue(subscriptionID: id) }
        let notes = PushNotes(
            // The extension only appends: the app trims, so a push never reads and rewrites the file.
            journal: DiagnosticsJournal(
                fileURL: DiagnosticsJournal.place(container: container, fallback: container), trims: false),
            subscription: PushNoticeLog.fingerprint(id))
        self.notes = notes
        let account = registry.registration(subscriptionID: id)?.account
        let accountName = account.map { $0.displayName.isEmpty ? $0.email : $0.displayName } ?? ""
        let work = Task {
            let done = await Self.update(id, container: container, registry: registry, credentials: credentials)
            let (rows, why) = (done.rows, done.why)
            if why == .found { StoreChanges.post() }
            let notice = NewMailNotice(
                rows, accountName: accountName, protectedBody: String(localized: "push.encrypted")
            ) { count in
                String(localized: "push.newMessages \(count)")
            }
            delivery.deliver(notice.flatMap { Found($0, rows: rows) }, badge: done.badge) { shown in
                notes.note(why, count: why == .found ? rows.count : nil, shown: shown)
            }
        }
        Task {
            try? await Task.sleep(for: Self.deadline)
            work.cancel()
            delivery.deliver(nil) { notes.note(.outOfTime, shown: $0) }
        }
    }

    /// What a push's update brought: the new mail, why, and the app icon's number after it.
    private struct Update {
        var rows: [MessageRow] = []
        var why: ProbeWhy
        var badge: Int?
    }

    /// The pushed account's Inbox brought up to date in the store the app shares, and what came.
    /// Only a store the app made and brought up to date: none yet, or one not migrated yet, means
    /// the app has not run since the update.
    private static func update(
        _ id: String, container: URL, registry: PushRegistry, credentials: CredentialProvider
    ) async -> Update {
        let place = PushPlaces.store(in: container)
        guard FileManager.default.fileExists(atPath: place.path), let store = try? MailStore(current: place) else {
            return Update(why: .serverFailed)
        }
        let pushed = PushedInbox(store: store, credentials: credentials) {
            registry.registration(subscriptionID: $0)?.account
        }
        let (rows, why) = await pushed.update(subscriptionID: id, budget: budget)
        // Counted as the app counts it (`BadgeDefaults`); none when the store will not answer.
        let badge = try? store.unreadInboxCount(focusedOnly: BadgeDefaults.focusedOnly)
        return Update(rows: rows, why: why, badge: badge)
    }

    /// iOS is about to give up on the extension: the generic text goes out now.
    override func serviceExtensionTimeWillExpire() {
        let notes = notes
        delivery?.deliver(nil) { notes?.note(.outOfTime, shown: $0) }
    }
}

/// What a notification that found mail shows, and what its tap opens: the message, or the
/// account's Inbox for several. Grouped by account, as the local notices are.
private struct Found {
    let notice: NewMailNotice
    let thread: String
    let tap: [String: Any]

    init?(_ notice: NewMailNotice, rows: [MessageRow]) {
        guard let first = rows.first else { return nil }
        self.notice = notice
        thread = first.accountID.raw.uuidString
        tap = NewMailPlan.userInfo(account: first.accountID, message: rows.count == 1 ? first.id : nil)
    }
}

/// Calls the content handler once: on the update's answer, the deadline or iOS's warning,
/// whichever comes first. Unchecked because UserNotifications does not mark the handler and the
/// content Sendable; both are only touched here, the handler at most once under the lock, and
/// iOS takes the handler's call on any thread.
private final class Delivery: @unchecked Sendable {
    private let handler: (UNNotificationContent) -> Void
    private let original: UNNotificationContent
    private let done = Mutex(false)

    private let first: @Sendable () -> Void

    /// `first` runs once, before the handler is called.
    init(
        _ handler: @escaping (UNNotificationContent) -> Void, original: UNNotificationContent,
        first: @escaping @Sendable () -> Void
    ) {
        self.handler = handler
        self.original = original
        self.first = first
    }

    /// The original content, with the notice's title and body when there is one, the app icon's
    /// number when known, quiet under Do Not Disturb. `noting` is told what iOS is handed, before
    /// it is handed over (iOS may end the extension right after); the calls after the first do
    /// nothing.
    func deliver(_ found: Found?, badge: Int? = nil, noting: (PushNoticeLog.Shown) -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else {
            return
        }
        self.first()
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else {
            noting(.plain)
            handler(original)
            return
        }
        if let found {
            content.title = found.notice.title
            content.body = found.notice.body
            content.threadIdentifier = found.thread
            content.userInfo = content.userInfo.merging(found.tap) { _, tapped in tapped }
        }
        if let badge { content.badge = NSNumber(value: badge) }
        // Do Not Disturb: the notification still lands in Notification Centre, quietly.
        if DoNotDisturbDefaults.load().isActive(at: Date()) {
            content.interruptionLevel = .passive
            content.sound = nil
        }
        noting(found == nil ? .plain : .details)
        handler(content)
    }
}

/// The pushes this extension process is working on (iOS may reuse it, and run two at once): the
/// store is open while there are any, and suspended (`MailStore.suspendSharing`) when the last one
/// has delivered, so a frozen extension holds no lock the app would wait on.
private enum StoreUse {
    private static let working = Mutex(0)

    static func begin() {
        working.withLock { $0 += 1 }
        MailStore.resumeSharing()
    }

    static func end() {
        let left = working.withLock { count in
            count = max(0, count - 1)
            return count
        }
        if left == 0 {
            MailStore.suspendSharing()
        }
    }
}

/// One push's note in the diagnostics journal: its subscription's fingerprint, why it showed what
/// it showed, the extension's time since the push came and the memory it had left then.
private struct PushNotes: Sendable {
    let journal: DiagnosticsJournal
    let subscription: String
    let started = ContinuousClock.now

    func note(_ why: ProbeWhy, count: Int? = nil, shown: PushNoticeLog.Shown) {
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        journal.note(.push(
            subscription: subscription, why: why, count: count, shown: shown, milliseconds: milliseconds,
            availableKB: Self.availableKB()))
    }

    /// How much more memory iOS lets the extension take (its limit less what it holds).
    private static func availableKB() -> Int {
        Int(os_proc_available_memory() / 1_024)
    }
}
