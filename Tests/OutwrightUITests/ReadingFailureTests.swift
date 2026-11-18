// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

/// When the locked web view gives up on a message's HTML for its plain text.
@Suite struct ReadingFailureTests {
    @Test func aPageThatNeverStartedFallsBackToText() {
        #expect(ReadingFailure.needsText(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData, shown: false))
        #expect(ReadingFailure.needsText(domain: "WebKitErrorDomain", code: 101, shown: false))
    }

    /// A link tap, a redirect, a refresh or a frame the view cancels itself is no failure of the page.
    @Test func cancelledOrInterruptedNeverFallsBack() {
        for shown in [false, true] {
            #expect(!ReadingFailure.needsText(domain: NSURLErrorDomain, code: NSURLErrorCancelled, shown: shown))
            #expect(!ReadingFailure.needsText(domain: "WebKitErrorDomain", code: 102, shown: shown))
        }
    }

    /// A body already read stays as it is.
    @Test func nothingFallsBackOnceShown() {
        #expect(!ReadingFailure.needsText(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData, shown: true))
    }

    /// The page's process ended: text before anything was shown; once shown, the page loads again once,
    /// and a second end falls back.
    @Test func aTerminatedProcessReloadsOnceThenFallsBack() {
        #expect(ReadingFailure.afterTermination(shown: false, reloaded: false) == .showText)
        #expect(ReadingFailure.afterTermination(shown: true, reloaded: false) == .reload)
        #expect(ReadingFailure.afterTermination(shown: true, reloaded: true) == .showText)
        #expect(ReadingFailure.afterTermination(shown: false, reloaded: true) == .showText)
    }
}
