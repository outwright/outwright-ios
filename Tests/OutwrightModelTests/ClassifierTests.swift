// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import Testing

@testable import OutwrightModel

@Suite struct ClassifierTests {
    let stranger = Address(name: "News", email: "news@example.org")

    @Test func bulkFromStrangerIsOther() {
        let c = FocusedClassifier.classify(
            from: stranger, isBulk: true, isReplyToOwn: false, correspondents: [], overrides: [:])
        #expect(c == .other)
    }

    @Test func bulkFromCorrespondentIsFocused() {
        let c = FocusedClassifier.classify(
            from: stranger, isBulk: true, isReplyToOwn: false,
            correspondents: ["news@example.org"], overrides: [:])
        #expect(c == .focused)
    }

    @Test func overrideWins() {
        let toOther = FocusedClassifier.classify(
            from: Address(name: nil, email: "Anna@Example.org"), isBulk: false, isReplyToOwn: true,
            correspondents: ["anna@example.org"], overrides: ["anna@example.org": .other])
        #expect(toOther == .other)
        let toFocused = FocusedClassifier.classify(
            from: stranger, isBulk: true, isReplyToOwn: false, correspondents: [],
            overrides: ["news@example.org": .focused])
        #expect(toFocused == .focused)
    }

    @Test func personalMailIsFocused() {
        let c = FocusedClassifier.classify(
            from: stranger, isBulk: false, isReplyToOwn: false, correspondents: [], overrides: [:])
        #expect(c == .focused)
    }
}
