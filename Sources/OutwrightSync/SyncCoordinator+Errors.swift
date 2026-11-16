// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// What each account last failed with, for the banner.
extension SyncCoordinator {
    /// Keeps what the account last failed with, for the banner. A first failure to reach the
    /// server in a row is passed over (the network may not be back yet when the app comes to the
    /// front, and the retry decides); from the second on it is kept.
    func record(_ id: AccountID, _ error: SyncError?) {
        guard let error else {
            lastErrors[id] = nil
            unreachableInARow[id] = nil
            return
        }
        syncLog.error("Sync failed: \(caseName(error), privacy: .public): \(String(describing: error))")
        if error.isUnreachable {
            let count = (unreachableInARow[id] ?? 0) + 1
            unreachableInARow[id] = count
            guard count > 1 else {
                return
            }
        } else {
            unreachableInARow[id] = nil
        }
        lastErrors[id] = error
    }
}
