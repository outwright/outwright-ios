// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightUI

/// On a phone the tabs never show over a message or a card pushed over its list, whatever order
/// the list's appearance and the tab's return come in; a swipe back still brings them as it begins.
@Suite struct PushedListTests {
    @Test func nothingPushedNeverCovers() {
        #expect(!PushedList.covers(path: [Int](), listInView: false))
        #expect(!PushedList.covers(path: [Int](), listInView: true))
    }

    @Test func somethingPushedCoversUntilTheListComesBack() {
        #expect(PushedList.covers(path: [1], listInView: false))
        #expect(!PushedList.covers(path: [1], listInView: true))
    }

    /// The list appears under a pushed message as its tab comes back: the message keeps the screen.
    @Test func aTabComingBackDoesNotBringTheListOverAPush() {
        let inView = PushedList.inViewOnAppear(path: [1], tabReturning: true)
        #expect(PushedList.covers(path: [1], listInView: inView))
    }

    /// The list appears under a pushed message as a swipe back begins: the tabs come with it.
    @Test func aSwipeBackBringsTheList() {
        let inView = PushedList.inViewOnAppear(path: [1], tabReturning: false)
        #expect(!PushedList.covers(path: [1], listInView: inView))
    }

    @Test func aListWithNothingPushedIsInView() {
        #expect(PushedList.inViewOnAppear(path: [Int](), tabReturning: true))
        #expect(PushedList.inViewOnAppear(path: [Int](), tabReturning: false))
    }
}
