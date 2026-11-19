// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import Testing

@testable import OutwrightUI

@Suite struct SetupRowsTests {
    func item(_ kind: SetupItem.Kind, _ label: String) -> SetupItem { SetupItem(kind: kind, label: label) }

    /// Contacts' keys are counted, never listed one by one; the rest keep their order.
    @Test func contactKeysAreCounted() {
        let items = [
            item(.account, "pat@example.org"), item(.contactKey, "kim (1)"),
            item(.contactKey, "lee (2)"), item(.addressSettings, "pat@example.org")
        ]
        #expect(SetupRow.rows(items) == [
            .item(item(.account, "pat@example.org")), .counted(.contactKey, 2),
            .item(item(.addressSettings, "pat@example.org"))
        ])
    }

    /// What was not added is counted by kind and reason, so "Already here" is never repeated row after row.
    @Test func skipsAreCountedByKindAndReason() {
        let skips = [
            SetupSkip(item: item(.account, "pat@example.org"), reason: .failed),
            SetupSkip(item: item(.contactKey, "kim (1)"), reason: .alreadyHere),
            SetupSkip(item: item(.contactKey, "lee (2)"), reason: .failed),
            SetupSkip(item: item(.contactKey, "max (3)"), reason: .alreadyHere)
        ]
        #expect(SetupRow.skipRows(skips) == [
            SetupSkipRow(row: .item(item(.account, "pat@example.org")), reason: .failed),
            SetupSkipRow(row: .counted(.contactKey, 2), reason: .alreadyHere),
            SetupSkipRow(row: .counted(.contactKey, 1), reason: .failed)
        ])
    }

    /// A part with nothing fit to show gets the screen's own word; a title is shown as it is.
    @Test func anUnnamedPartGetsAPlaceholder() {
        #expect(!SetupRow.partName("").isEmpty)
        #expect(SetupRow.partName("Future things") == "Future things")
    }
}
