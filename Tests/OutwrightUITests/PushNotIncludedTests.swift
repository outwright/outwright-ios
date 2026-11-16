// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import Synchronization
import Testing

@testable import OutwrightUI

@MainActor @Suite struct PushNotIncludedTests {
    @Test func pushOnWithoutItGoesLocal() async throws {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        try await switcher.enable(anna)
        await movePushToLocal(accounts: [anna], push: switcher, local: local, included: false)
        #expect(await !switcher.isEnabled(anna.id))
        #expect(await local.isOn(anna.id))
    }

    @Test func pushOnWithItStays() async throws {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        try await switcher.enable(anna)
        await movePushToLocal(accounts: [anna], push: switcher, local: local, included: true)
        #expect(await switcher.isEnabled(anna.id))
        #expect(await !local.isOn(anna.id))
    }

    @Test func localIsOnBeforePushGoesOff() async throws {
        let local = FakeLocal()
        let seen = Mutex<Bool?>(nil)
        let switcher = FakeSwitch(onDisable: { id in
            let on = await local.isOn(id)
            seen.withLock { $0 = on }
        })
        let anna = account()
        try await switcher.enable(anna)
        await movePushToLocal(accounts: [anna], push: switcher, local: local, included: false)
        #expect(seen.withLock { $0 } == true)
    }

    @Test func failingDisableStillTurnsLocalOn() async throws {
        let switcher = FakeSwitch(disableFailure: .limit)
        let local = FakeLocal()
        let anna = account()
        try await switcher.enable(anna)
        await movePushToLocal(accounts: [anna], push: switcher, local: local, included: false)
        #expect(await local.isOn(anna.id))
    }

    @Test func accountWithoutPushIsLeft() async {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        await movePushToLocal(accounts: [anna], push: switcher, local: local, included: false)
        #expect(await !switcher.isEnabled(anna.id))
        #expect(await !local.isOn(anna.id))
    }
}
