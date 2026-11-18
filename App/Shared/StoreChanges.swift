// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import notify
import OutwrightSync

/// The notification extension's word to the app that it stored new mail in the store they share,
/// a Darwin notification named after the app group (it carries nothing). The app's lists look
/// again on it: what another process writes is never seen otherwise.
enum StoreChanges {
    private static var name: String? {
        BuildSettings.main.appGroup.map { $0 + ".store-changed" }
    }

    static func post() {
        guard let name else { return }
        notify_post(name)
    }

    /// `changed` on the main queue for each word, for as long as the app runs.
    static func observe(_ changed: @escaping @MainActor () -> Void) {
        guard let name else { return }
        var token: Int32 = 0
        notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }
}
