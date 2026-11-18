// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// When the locked web view gives up on a message's HTML and the plain text takes its place.
enum ReadingFailure {
    /// What follows the end of the page's process.
    enum Step: Equatable {
        case showText
        /// Our own page is loaded again.
        case reload
    }

    /// WebKit's "frame load interrupted": the view cancelled the navigation itself.
    private static let interrupted = (domain: "WebKitErrorDomain", code: 102)

    /// A navigation failed. Only a page that never showed falls back; a navigation the view cancelled
    /// itself (a link tap, a redirect, a refresh, a frame) is no failure of the page.
    static func needsText(domain: String, code: Int, shown: Bool) -> Bool {
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled { return false }
        if domain == interrupted.domain && code == interrupted.code { return false }
        return !shown
    }

    /// The page's process ended (hostile HTML can bring it down). Before anything showed, the text
    /// stands in; a body already read loads again once, and a second end falls back.
    static func afterTermination(shown: Bool, reloaded: Bool) -> Step {
        shown && !reloaded ? .reload : .showText
    }
}
