// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
public import SwiftUI

/// A section a module adds to an account's settings, joined to the shared code at app start. The
/// shared code shows what it gives, in the order registered, and never names the module.
@MainActor public protocol AccountSection: AnyObject {
    func section(for account: Account) -> AnyView
}
