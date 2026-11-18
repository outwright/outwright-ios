// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import Testing

@testable import OutwrightUI

@Suite struct SetupRowsTests {
    func item(_ kind: SetupItem.Kind, _ label: String) -> SetupItem { SetupItem(kind: kind, label: label) }

    /// Settings and contacts' keys are counted, never listed one by one; the rest keep their order.
    @Test func settingsAndContactKeysAreCounted() {
        let items = [
            item(.settings, "focusedInbox"), item(.account, "pat@example.org"), item(.contactKey, "kim (1)"),
            item(.settings, "swipeLeading"), item(.contactKey, "lee (2)"), item(.addressSettings, "pat@example.org")
        ]
        #expect(SetupRow.rows(items) == [
            .counted(.settings, 2), .item(item(.account, "pat@example.org")), .counted(.contactKey, 2),
            .item(item(.addressSettings, "pat@example.org"))
        ])
    }

    /// What was not added is counted by kind and reason, so "Already here" is never repeated row after row.
    @Test func skipsAreCountedByKindAndReason() {
        let skips = [
            SetupSkip(item: item(.settings, "focusedInbox"), reason: .alreadyHere),
            SetupSkip(item: item(.settings, "swipeLeading"), reason: .alreadyHere),
            SetupSkip(item: item(.account, "pat@example.org"), reason: .failed),
            SetupSkip(item: item(.contactKey, "kim (1)"), reason: .alreadyHere),
            SetupSkip(item: item(.contactKey, "lee (2)"), reason: .failed),
            SetupSkip(item: item(.settings, "calendarMode"), reason: .failed),
            SetupSkip(item: item(.contactKey, "max (3)"), reason: .alreadyHere)
        ]
        #expect(SetupRow.skipRows(skips) == [
            SetupSkipRow(row: .counted(.settings, 2), reason: .alreadyHere),
            SetupSkipRow(row: .item(item(.account, "pat@example.org")), reason: .failed),
            SetupSkipRow(row: .counted(.contactKey, 2), reason: .alreadyHere),
            SetupSkipRow(row: .counted(.contactKey, 1), reason: .failed),
            SetupSkipRow(row: .counted(.settings, 1), reason: .failed)
        ])
    }

    /// A part with nothing fit to show gets the screen's own word; a title is shown as it is.
    @Test func anUnnamedPartGetsAPlaceholder() {
        #expect(!SetupRow.partName("").isEmpty)
        #expect(SetupRow.partName("Future things") == "Future things")
    }
}
