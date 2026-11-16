// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Settings, opened at the list or at one account.
extension AppModel {
    /// Opens settings at the list of accounts.
    public func showSettings() {
        settingsAccount = nil
        isShowingSettings = true
    }

    /// A sync problem's banner was tapped: settings opens at that account, where its password and
    /// servers are put right; at the list when the account is gone (a banner not yet read again).
    public func showSettings(for problem: AccountProblem) {
        let id = problem.account.id
        settingsAccount = accounts.contains { $0.id == id } ? id : nil
        isShowingSettings = true
    }
}
