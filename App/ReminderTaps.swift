// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import OutwrightUI
import UserNotifications

/// A tapped reminder opens its event's details and a tapped new-mail notice its message; a reminder
/// that fires while the app is in front is shown as a banner too. Other notifications are left as
/// they were.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notification = response.notification.request
        if NewMailPlan.isNewMail(identifier: notification.identifier, userInfo: notification.content.userInfo) {
            if let request = MessageRequest(userInfo: notification.content.userInfo) {
                Task { @MainActor in
                    // The tap may come before the app is in front: the store is taken back first,
                    // since opening the message writes (read, its body).
                    StoreGrace.sharing.cameToFront()
                    OutwrightApp.open(request)
                }
            }
        } else if let request = EventRequest(userInfo: notification.content.userInfo) {
            Task { @MainActor in OutwrightApp.open(request) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isReminder = notification.request.identifier.hasPrefix(ReminderPlan.identifierPrefix)
        completionHandler(isReminder ? [.banner, .list, .sound] : [])
    }
}
