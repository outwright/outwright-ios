// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// Mail as the list and the reading view need it from sync: a body, and whether an account is still
/// getting its mail for the first time.
extension AppModel {
    /// The account is synced and its first look at its Inbox has not ended yet: an empty list is mail
    /// on its way. Known from the last `updateFirstSync`.
    public func isFirstSync(_ account: AccountID) -> Bool {
        awaitingFirstInbox.contains(account)
    }

    /// Asks the coordinator which synced accounts have not had their Inbox looked at.
    public func updateFirstSync() async {
        awaitingFirstInbox = await sync.awaitingFirstInbox()
    }

    public func fetchBody(_ message: MessageID) async {
        try? await sync.fetchBody(message)
    }
}
