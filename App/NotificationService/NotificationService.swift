// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightPush
import OutwrightSync
import Synchronization
import UserNotifications

/// Runs when a push comes: asks the account's Inbox what came, from the phone, and puts the
/// sender and subject in place of the generic "New mail". The push itself carries only the
/// subscription id. Whatever goes wrong, the generic notification is delivered, in time.
final class NotificationService: UNNotificationServiceExtension {
    /// The probe's time; iOS gives the extension about 30 s in all.
    static let budget = Duration.seconds(20)
    /// The original content goes out by then whatever the probe is doing.
    static let deadline = Duration.seconds(25)
    static let maxSubscriptionID = 128

    private var delivery: Delivery?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let original = request.content
        let delivery = Delivery(contentHandler, original: original)
        self.delivery = delivery
        guard let id = original.userInfo["s"] as? String, !id.isEmpty, id.utf8.count <= Self.maxSubscriptionID,
            let container = PushPlaces.container
        else {
            delivery.deliver(nil)
            return
        }
        let registry = PushRegistry(fileURL: PushPlaces.registry(in: container), vault: KeychainPushVault())
        let marks = PushWatermarks(fileURL: PushPlaces.watermarks(in: container))
        let credentials = CredentialProvider(
            secrets: KeychainSecretStore(), tokens: ExtensionComposition.tokenRenewals())
        let probe = NewMailProbe(
            account: { registry.registration(subscriptionID: $0)?.account }, credentials: credentials, marks: marks)
        // Beside the probe, never before the notification: a push method's server side that lapses
        // unless renewed is moved on, at most every 12 hours.
        let renewal = ExtensionRenewal(
            registry: registry, relay: BuildSettings.main.relay.map { RelayClient(base: $0) },
            methods: ExtensionComposition.pushMethods(credentials: credentials), marks: marks)
        Task { await renewal.renewIfDue(subscriptionID: id) }
        let account = registry.registration(subscriptionID: id)?.account
        let accountName = account.map { $0.displayName.isEmpty ? $0.email : $0.displayName } ?? ""
        let work = Task {
            let result = await probe.run(subscriptionID: id, budget: Self.budget)
            let notice = NewMailNotice(
                result, accountName: accountName, protectedBody: String(localized: "push.encrypted")
            ) { count in
                String(localized: "push.newMessages \(count)")
            }
            delivery.deliver(notice.map { (notice: $0, thread: id) })
        }
        Task {
            try? await Task.sleep(for: Self.deadline)
            work.cancel()
            delivery.deliver(nil)
        }
    }

    /// iOS is about to give up on the extension: the generic text goes out now.
    override func serviceExtensionTimeWillExpire() {
        delivery?.deliver(nil)
    }
}

/// Calls the content handler once: on the probe's answer, the deadline or iOS's warning,
/// whichever comes first. Unchecked because UserNotifications does not mark the handler and the
/// content Sendable; both are only touched here, the handler at most once under the lock, and
/// iOS takes the handler's call on any thread.
private final class Delivery: @unchecked Sendable {
    private let handler: (UNNotificationContent) -> Void
    private let original: UNNotificationContent
    private let done = Mutex(false)

    init(_ handler: @escaping (UNNotificationContent) -> Void, original: UNNotificationContent) {
        self.handler = handler
        self.original = original
    }

    /// The original content, with the notice's title and body when there is one.
    func deliver(_ found: (notice: NewMailNotice, thread: String)?) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else {
            return
        }
        guard let found, let content = original.mutableCopy() as? UNMutableNotificationContent else {
            handler(original)
            return
        }
        content.title = found.notice.title
        content.body = found.notice.body
        content.threadIdentifier = found.thread
        handler(content)
    }
}
