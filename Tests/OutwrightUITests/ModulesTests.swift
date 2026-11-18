// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI
import Testing

@testable import OutwrightUI

@MainActor private final class StubScreens: ProtectionUI {
    let protection: ProtectionID
    init(_ raw: String) { protection = ProtectionID(raw: raw) }
    func compose(
        recipients: [Address], account: Account, original: ProtectionFacts?, ownerLock: Bool?, ownerSign: Bool?
    ) async -> ComposeProtection { ComposeProtection(lockOn: false, mustAsk: false, recipients: [:]) }
    func keyImporter(for address: String, account: Account?) -> AnyView { AnyView(EmptyView()) }
    func readingMarks(
        _ facts: ProtectionFacts, sender: Address, reverify: @escaping @MainActor () async -> Void
    ) -> AnyView { AnyView(EmptyView()) }
    func personSection(for address: String) -> AnyView { AnyView(EmptyView()) }
    func accountSetup(for account: Account) -> AnyView? { nil }
}

@MainActor @Suite struct ModulesTests {
    @Test func screensForIDPicksMatchingAndNilPicksFirst() {
        let a = StubScreens("a")
        let b = StubScreens("b")
        var modules = Modules()
        modules.protectionScreens = [a, b]
        #expect(modules.screens(for: ProtectionID(raw: "b")) === b)
        #expect(modules.screens(for: nil) === a)
        #expect(modules.screens(for: ProtectionID(raw: "c")) == nil)
        #expect(Modules().screens(for: nil) == nil)
    }
}
