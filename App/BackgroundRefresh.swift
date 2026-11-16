// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import BackgroundTasks
import Foundation
import OutwrightUI

/// Background app refresh: iOS wakes the app now and then to fetch new mail. The identifier is
/// listed in Info.plist's `BGTaskSchedulerPermittedIdentifiers` (App/app.yml).
enum BackgroundRefresh {
    static let identifier = "com.10boring.outwright.refresh"
    static let interval: TimeInterval = 15 * 60

    /// Whether the owner lets the app refresh in the background (Settings; on unless turned off).
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.backgroundRefresh) as? Bool ?? true
    }

    /// Asks for the next refresh 15 minutes from now (iOS decides when it really runs); turned off,
    /// cancels the one asked for instead.
    static func schedule() {
        guard isOn else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
