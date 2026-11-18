// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel

/// A message handed to the outbox, for the "Sending…" toast.
public struct SendingMail: Equatable, Sendable {
    public let id = UUID()
    public let draft: MessageID
}

/// After Send: a toast while the message goes. A refusal is the account's attention, on every tab.
extension AppModel {
    /// The compose sheet sent `draft`: the toast shows while the accounts are refreshed (which sends it).
    func sent(_ draft: MessageID) async {
        let current = SendingMail(draft: draft)
        sending = current
        await sync.refreshAll()
        // Sent once the refresh is done: the toast goes then, not after the modules have been asked.
        if sending == current { sending = nil }
        // A refusal shows its banner now, not at the next look.
        await updateAttention()
    }
}
