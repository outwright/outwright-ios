// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Testing

@testable import OutwrightUI

@MainActor @Suite struct PresenceBindingTests {
    private final class Holder {
        var problem: String?
    }

    @Test func anAlertIsUpWhileItsItemIsThereAndDismissingClearsIt() {
        let holder = Holder()
        let item = Binding { holder.problem } set: { holder.problem = $0 }
        let isPresented = Binding(presenting: item)
        #expect(!isPresented.wrappedValue)
        holder.problem = "too large"
        #expect(isPresented.wrappedValue)
        isPresented.wrappedValue = true
        #expect(holder.problem == "too large")
        isPresented.wrappedValue = false
        #expect(holder.problem == nil)
    }
}
