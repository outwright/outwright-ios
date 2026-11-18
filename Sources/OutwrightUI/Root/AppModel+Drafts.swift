// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// Drafts, opened from the Drafts button or a message that wasn't sent, and closed back to where it
/// was opened from.
extension AppModel {
    /// The Drafts of the account in view, or of the first account.
    public func openDrafts() {
        guard let account = accountInView ?? accounts.first else { return }
        openDrafts(of: account.id)
    }

    /// The account's Drafts; Back goes to where it was opened from.
    func openDrafts(of account: AccountID) {
        guard let drafts = (try? store.folders(account))?.first(where: { $0.kind == .drafts }) else { return }
        let previous = isInDrafts ? scopeBeforeDrafts : scope
        open(drafts.id)
        scopeBeforeDrafts = previous
    }

    /// A Drafts folder is in view: the list offers a way back instead of Drafts and New mail.
    public var isInDrafts: Bool {
        folderInView?.kind == .drafts
    }

    /// Back from Drafts to where the Drafts button was pressed, else to that account's Inbox.
    public func closeDrafts() {
        if let previous = scopeBeforeDrafts {
            scope = previous
        } else if let account = accountInView,
            let inbox = (try? store.folders(account.id))?.first(where: { $0.kind == .inbox }) {
            scope = .folder(inbox.id)
        } else {
            scope = .allAccounts
        }
        scopeBeforeDrafts = nil
    }
}
