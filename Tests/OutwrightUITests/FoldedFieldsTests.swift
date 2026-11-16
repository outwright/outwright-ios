// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import Testing

@testable import OutwrightUI

@MainActor @Suite struct FoldedFieldsTests {
    @Test func aRecipientWithAnEmptyNameShowsTheAddress() {
        let line = FoldedFields.names([
            Address(name: "Bo", email: "bo@example.org"), Address(name: "", email: "cia@example.org"),
        ])
        #expect(line == "Bo, cia@example.org")
    }
}
