// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

@objc(OutwrightTestHooks)
@MainActor
final class TestHooks: NSObject, LaunchHooks {
    var clockOffset: TimeInterval { 90 }
}

@MainActor
@Suite struct LaunchHooksTests {
    @Test func noHooksMeansTheRealClockAndNoSample() {
        let hooks = LaunchHookSet(named: [])
        #expect(hooks.clockOffset == 0)
        #expect(hooks.sampleModel() == nil)
        #expect(!hooks.startsSample)
    }

    @Test func hooksAreFoundByTheirName() {
        let hooks = LaunchHookSet(named: ["OutwrightTestHooks"])
        #expect(hooks.clockOffset == 90)
    }

    @Test func aNameThatIsNoHookIsIgnored() {
        #expect(LaunchHookSet(named: ["NoSuchClass", "NSObject"]).clockOffset == 0)
    }
}
