// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

extension Account {
    /// This account placed after `existing`, as a new one is: the next colour of `colors`, the
    /// last place in the list (saved data may hold any order number; it never overflows).
    public func placed(after existing: [Account], colors: Int) -> Account {
        let last = existing.map(\.sortOrder).max() ?? -1
        let (next, overflow) = last.addingReportingOverflow(1)
        var account = self
        account.colorIndex = colors > 0 ? existing.count % colors : 0
        account.sortOrder = overflow ? Int.max : next
        return account
    }
}
