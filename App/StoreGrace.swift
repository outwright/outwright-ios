// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightStore
import UIKit

/// The app's `StoreSharing`, its grace a UIKit background task: what was started before going to
/// the background (a draft saved, a send, a sync) finishes before the store is let go.
@MainActor
enum StoreGrace {
    static let sharing = StoreSharing { expired in
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "Outwright store") {
            MainActor.assumeIsolated { expired() }
        }
        guard task != .invalid else { return nil }
        return {
            guard task != .invalid else { return }
            application.endBackgroundTask(task)
            task = .invalid
        }
    }
}
