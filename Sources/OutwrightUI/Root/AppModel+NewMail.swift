// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightModel

extension AppModel {
    /// After a background refresh: new Inbox mail of the accounts with local notices on is
    /// announced; an account with push on is left to push. With Focused Inbox on, only Focused mail.
    public func announceNewMail(defaults: UserDefaults = .standard) async {
        var pushed: Set<AccountID> = []
        if let push {
            for account in accounts where await push.switcher.isEnabled(account.id) {
                pushed.insert(account.id)
            }
        }
        let focusedOnly = defaults.object(forKey: SettingsKeys.focusedInbox) as? Bool ?? true
        let protectedBody = String(localized: "Encrypted message", bundle: .module)
        await sync.announceNewMail(skipping: pushed, focusedOnly: focusedOnly, protectedBody: protectedBody) { count in
            String(localized: "\(count) more new messages", bundle: .module)
        }
    }

    /// A tapped new-mail notice, on the Mail tab: its message opens in the list's place; the
    /// summary of many opens its account's Inbox. A sheet in front stays, with the mail behind it.
    public func showMessage(_ request: MessageRequest) {
        selectedTab = .mail
        isDrawerOpen = false
        if let message = request.message {
            messageToOpen = message
        } else if let account = request.account {
            let inbox = (try? store.folders(account))?.first { $0.kind == .inbox }
            if let inbox { scope = .folder(inbox.id) }
        }
    }
}
