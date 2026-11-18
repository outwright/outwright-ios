// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
public import SwiftUI

/// What a build offers for an account whose server push is not on, joined at app start: a row
/// under the account's Notifications switch that opens it, shown while push is not on or while the
/// account uses it. The shared code shows the
/// row and never names the module.
@MainActor public protocol PushAlternative: AnyObject {
    /// Whether the account can use it at all.
    func offers(_ account: Account) -> Bool
    /// Whether the account already uses it, so its row stays while push is on (or no longer included).
    func isInUse(_ account: AccountID) async -> Bool
    /// The line in Settings › Notifications that points to the row in the account's settings.
    func note(for account: Account) -> String
    /// The row under the account's Notifications switch.
    func row(for account: Account) -> AnyView
}
