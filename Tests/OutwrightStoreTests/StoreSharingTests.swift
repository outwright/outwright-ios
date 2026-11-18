// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import OutwrightStore

/// When the app lets go of the store it shares with its notification extension: not while it is
/// in front, refreshing, or finishing in the grace iOS gives after going to the background; at
/// once when that grace runs out or a refresh is cut short.
@MainActor @Suite final class StoreSharingTests {
    /// What the stores were told, in order.
    final class Said: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    private let said = Said()
    private var expire: (@MainActor () -> Void)?
    private var ended = 0

    private func sharing(granted: Bool = true) -> StoreSharing {
        let said = said
        return StoreSharing(
            beginGrace: { [unowned self] expired in
                guard granted else { return nil }
                expire = expired
                return { [unowned self] in ended += 1 }
            },
            suspend: { said.add("suspend") },
            resume: { said.add("resume") })
    }

    private var last: String? { said.all.last }

    @Test func goingToTheBackgroundWaitsForTheGraceToRunOut() {
        let store = sharing()
        store.cameToFront()
        #expect(last == "resume")
        store.wentToBackground()
        #expect(last == "resume")
        expire?()
        #expect(last == "suspend")
        #expect(ended == 1)
    }

    @Test func noGraceSuspendsAtOnce() {
        let store = sharing(granted: false)
        store.cameToFront()
        store.wentToBackground()
        #expect(last == "suspend")
    }

    @Test func comingBackEndsTheGrace() {
        let store = sharing()
        store.wentToBackground()
        store.cameToFront()
        #expect(ended == 1)
        #expect(last == "resume")
    }

    @Test func aRefreshInTheBackgroundOpensItAndLetsGoAfter() async {
        let store = sharing(granted: false)
        store.wentToBackground()
        var during: String?
        await store.refresh { during = self.last }
        #expect(during == "resume")
        #expect(last == "suspend")
    }

    @Test func aRefreshCutShortLetsGoAtOnce() async {
        let store = sharing(granted: false)
        store.wentToBackground()
        let said = said
        let task = Task { @MainActor in
            await store.refresh {
                try? await Task.sleep(for: .seconds(30))
                said.add("body ended")
            }
        }
        while said.all.last != "resume" { await Task.yield() }
        task.cancel()
        await task.value
        #expect(said.all.suffix(3) == ["suspend", "body ended", "suspend"])
    }
}
