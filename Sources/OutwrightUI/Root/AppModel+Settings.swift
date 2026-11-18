// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel

/// Settings, opened at the list or at one account.
extension AppModel {
    /// Opens settings at the list of accounts.
    public func showSettings() {
        settingsAccount = nil
        isShowingSettings = true
    }

    /// Opens settings at one account (the drawer's gear, with the account in view), or at the list when nil.
    public func showSettings(account: AccountID?) {
        settingsAccount = account.flatMap { id in accounts.contains { $0.id == id } ? id : nil }
        isShowingSettings = true
    }
}

extension AppModel {
    /// The account new mail is from when none is in view (Settings › Default account); nil until chosen.
    public var defaultAccountID: AccountID? {
        UserDefaults.standard.string(forKey: SettingsKeys.defaultAccount).flatMap(UUID.init(uuidString:))
            .map { AccountID(raw: $0) }
    }
}
