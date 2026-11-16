// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightPush
import OutwrightSync
import OutwrightUI
import UIKit
import UserNotifications

/// The app's push: one controller over the relay, the keychain and the app group. Nil without
/// the app group's container.
@MainActor
enum AppPush {
    /// How often at most push is checked and the JMAP subscriptions' expiry moved on.
    static let renewEvery: TimeInterval = 12 * 3_600

    static let controller: PushController? = makeController()
    private static var lastRenewal: Date?

    /// Which APNs this build's device token belongs to: set by how the build is signed.
    static let environment = BuildSettings.main.apnsEnvironment

    private static func makeController() -> PushController? {
        guard let container = PushPlaces.container, let base = BuildSettings.main.relay else {
            return nil
        }
        let vault = KeychainPushVault()
        let secrets = KeychainSecretStore()
        let credentials = CredentialProvider(secrets: secrets, tokens: Composition.tokenRenewals())
        return PushController(
            relay: RelayClient(base: base), attester: AppAttester(vault: vault),
            registry: PushRegistry(fileURL: PushPlaces.registry(in: container), vault: vault),
            credentials: credentials, marks: PushWatermarks(fileURL: PushPlaces.watermarks(in: container)),
            environment: environment,
            methods: [JMAPPushMethod(secrets: secrets)] + Composition.pushMethods(credentials: credentials))
    }

    /// What settings needs for the Notifications switch.
    static func support() -> PushSupport? {
        guard let controller else {
            return nil
        }
        return PushSupport(
            switcher: TokenWaiting(controller: controller),
            offersPush: { await controller.offersPush($0) },
            askPermission: {
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
                    ?? false
            },
            registerForRemote: { UIApplication.shared.registerForRemoteNotifications() },
            setupGuide: { await controller.setupGuide(for: $0) })
    }

    /// Checks push with the relay and moves the subscriptions' expiry on, at most every 12
    /// hours: when the app comes forward and from background refresh.
    static func renewIfDue(now: Date = Date()) async {
        guard let controller else {
            return
        }
        if let lastRenewal, now.timeIntervalSince(lastRenewal) < renewEvery {
            return
        }
        lastRenewal = now
        await controller.renewAll()
    }
}

/// Switching on right after asking for remote notifications can come before APNs has answered
/// with the device token: `enable` is tried again for a few seconds while the token is missing.
struct TokenWaiting: PushSwitching {
    static let tries = 10
    static let wait = Duration.milliseconds(500)
    let controller: PushController

    func isEnabled(_ account: AccountID) async -> Bool {
        await controller.isEnabled(account)
    }

    func enable(_ account: Account) async throws(PushError) {
        for _ in 1..<Self.tries {
            do {
                try await controller.enable(account)
                return
            } catch .noDeviceToken {
                try? await Task.sleep(for: Self.wait)
            }
        }
        try await controller.enable(account)
    }

    func disable(_ account: AccountID) async throws(PushError) {
        try await controller.disable(account)
    }

    func accountChanged(_ account: Account) async {
        await controller.accountChanged(account)
    }
}

/// Hands the APNs device token to push, from every launch, and takes the reminders' taps
/// (`ReminderTaps.swift`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if !OutwrightApp.isSample, AppPush.controller != nil {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let controller = AppPush.controller else {
            return
        }
        Task { await controller.setDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // No token: switching push on says it could not, and the next launch asks again.
    }

    /// The relay's background wake (`w`: a subscription id) a day before something of push lapses
    /// (a server-side subscription the relay knows the expiry of): push is renewed now, whenever
    /// it last was.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let wake = userInfo["w"] as? String, !wake.isEmpty, wake.utf8.count <= 128 else {
            return .noData
        }
        guard let controller = AppPush.controller else {
            return .noData
        }
        await controller.renewAll()
        return .newData
    }
}
