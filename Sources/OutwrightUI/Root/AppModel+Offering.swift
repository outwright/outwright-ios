// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

extension AppModel {
    /// At launch: where the build's offering leaves push out, the accounts with push on go over
    /// to local notices. Nothing changes where push is included.
    public func movePushToLocalWhereNotIncluded() async {
        let included = modules.offering?.includes(.push) ?? true
        guard !included, let push else { return }
        let reminders = sync.reminders
        let local = StoreLocalNotifying(store: store) { await reminders.requestAuthorization() }
        // The stored accounts: at launch the app's list may not be loaded yet.
        let stored = (try? store.accounts()) ?? accounts
        await movePushToLocal(accounts: stored, push: push.switcher, local: local, included: included)
    }
}

/// Each account with push on goes over to local notices when push is not included: local notices
/// on first, so a stop in between never leaves an account with neither, then push switched off
/// (whatever the servers answer, as switching off does).
func movePushToLocal(
    accounts: [Account], push: (any PushSwitching)?, local: any LocalNotifying, included: Bool
) async {
    guard !included, let push else { return }
    for account in accounts where await push.isEnabled(account.id) {
        try? await local.set(true, for: account.id)
        try? await push.disable(account.id)
    }
}
