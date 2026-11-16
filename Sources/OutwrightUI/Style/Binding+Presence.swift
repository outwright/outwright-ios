// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

extension Binding where Value == Bool {
    /// True while `item` holds something; set false (an alert dismissed), it clears `item`.
    init<Item>(presenting item: Binding<Item?>) {
        self = item.isPresent
    }
}

extension Optional {
    /// True while there is a value; set false, it becomes nil. A key path rather than closures,
    /// which would capture the binding in a sendable closure.
    fileprivate var isPresent: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}
