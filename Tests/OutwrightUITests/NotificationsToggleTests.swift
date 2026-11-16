// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightPush
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add() { value.withLock { $0 += 1 } }
}

@MainActor @Suite struct NotificationsToggleTests {
    @Test func switchStartsOffWithoutPush() async {
        let model = NotificationsToggleModel(account: account(), support: nil, local: FakeLocal())
        await model.load()
        #expect(!model.isOn)
    }

    @Test func onWithoutPushTurnsLocalOn() async {
        let local = FakeLocal()
        let anna = account()
        let model = NotificationsToggleModel(account: anna, support: nil, local: local)
        await model.load()
        await model.set(true)
        #expect(model.isOn)
        #expect(model.isLocal)
        #expect(await local.isOn(anna.id))
    }

    @Test func onWithPushPrefersPush() async {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: local)
        await model.load()
        await model.set(true)
        #expect(switcher.enabled == [anna.id])
        #expect(await !local.isOn(anna.id))
        #expect(!model.isLocal)
    }

    @Test func onWithoutPushIncludedUsesLocalEvenWherePushIsOffered() async {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: local, pushIncluded: false)
        await model.load()
        await model.set(true)
        #expect(model.isOn)
        #expect(model.isLocal)
        #expect(switcher.enabled.isEmpty)
    }

    @Test func onWithPushIncludedPrefersPush() async {
        let switcher = FakeSwitch()
        let anna = account()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: FakeLocal(), pushIncluded: true)
        await model.load()
        await model.set(true)
        #expect(switcher.enabled == [anna.id])
        #expect(!model.isLocal)
    }

    @Test func pushIncludedAgainOffersPushOnTheNextTurnOn() async {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        let without = NotificationsToggleModel(account: anna, support: support, local: local, pushIncluded: false)
        await without.set(true)
        await without.set(false)
        let with = NotificationsToggleModel(account: anna, support: support, local: local, pushIncluded: true)
        await with.load()
        await with.set(true)
        #expect(switcher.enabled == [anna.id])
        #expect(!with.isLocal)
    }

    @Test func onWithPushButNoJMAPUsesLocal() async {
        let switcher = FakeSwitch()
        let local = FakeLocal()
        let anna = account()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in false }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: local)
        await model.load()
        await model.set(true)
        #expect(switcher.enabled.isEmpty)
        #expect(await local.isOn(anna.id))
    }

    @Test func deniedPermissionLeavesLocalOff() async {
        let local = FakeLocal(permission: false)
        let anna = account()
        let model = NotificationsToggleModel(account: anna, support: nil, local: local)
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .permissionDenied)
        #expect(await !local.isOn(anna.id))
    }

    /// A local failure is the phone's, not a server's.
    @Test func aLocalFailureSaysNotChanged() async {
        let model = NotificationsToggleModel(account: account(), support: nil, local: FakeLocal(fails: true))
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .notChanged)
    }

    @Test func offTurnsLocalOff() async {
        let local = FakeLocal()
        let anna = account()
        try? await local.set(true, for: anna.id)
        let model = NotificationsToggleModel(account: anna, support: nil, local: local)
        await model.load()
        #expect(model.isOn)
        await model.set(false)
        #expect(!model.isOn)
        #expect(await !local.isOn(anna.id))
    }

    @Test func toggleOnCallsEnable() async {
        let switcher = FakeSwitch()
        let registered = Counter()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true },
            registerForRemote: { registered.add() })
        let anna = account()
        let model = NotificationsToggleModel(account: anna, support: support, local: FakeLocal())
        await model.load()
        #expect(!model.isOn)
        await model.set(true)
        #expect(model.isOn)
        #expect(model.message == nil)
        #expect(switcher.enabled == [anna.id])
        #expect(registered.count == 1)
        await model.set(false)
        #expect(!model.isOn)
        #expect(await !switcher.isEnabled(anna.id))
    }

    @Test func enableFailureTurnsToggleBackOffWithMessage() async {
        let support = PushSupport(
            switcher: FakeSwitch(failure: .limit), offersPush: { _ in true }, askPermission: { true },
            registerForRemote: {})
        let model = NotificationsToggleModel(account: account(), support: support, local: FakeLocal())
        await model.load()
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .limit)

        let other = NotificationsToggleModel(
            account: account(),
            support: PushSupport(
                switcher: FakeSwitch(failure: .timeout), offersPush: { _ in true }, askPermission: { true },
                registerForRemote: {}),
            local: FakeLocal())
        await other.load()
        await other.set(true)
        #expect(!other.isOn)
        #expect(other.message == .failed)
    }

    @Test func notSetUpCarriesTheGuide() async throws {
        let guide = try #require(URL(string: "https://example.org/guide"))
        let support = PushSupport(
            switcher: FakeSwitch(failure: .notSetUp), offersPush: { _ in true }, askPermission: { true },
            registerForRemote: {}, setupGuide: { _ in guide })
        let model = NotificationsToggleModel(account: account(), support: support, local: FakeLocal())
        await model.load()
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .notSetUp(guide: guide))
    }

    @Test func serverRefusedIsItsOwnMessage() async {
        let support = PushSupport(
            switcher: FakeSwitch(failure: .serverRefused), offersPush: { _ in true }, askPermission: { true },
            registerForRemote: {})
        let model = NotificationsToggleModel(account: account(), support: support, local: FakeLocal())
        await model.load()
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .serverRefused)
    }

    @Test func permissionDeniedLeavesToggleOff() async {
        let switcher = FakeSwitch()
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { false }, registerForRemote: {})
        let model = NotificationsToggleModel(account: account(), support: support, local: FakeLocal())
        await model.load()
        await model.set(true)
        #expect(!model.isOn)
        #expect(model.message == .permissionDenied)
        #expect(switcher.enabled.isEmpty)
    }

    @Test func toggleStaysWhileOnEvenWithoutJMAP() async {
        let switcher = FakeSwitch()
        let anna = account()
        try? await switcher.enable(anna)
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in false }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: FakeLocal())
        await model.load()
        #expect(model.isOn)
    }

    @Test func disableFailureTurnsOffWithMessage() async {
        let switcher = FakeSwitch(disableFailure: .transport)
        let anna = account()
        try? await switcher.enable(anna)
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in true }, askPermission: { true }, registerForRemote: {})
        let model = NotificationsToggleModel(account: anna, support: support, local: FakeLocal())
        await model.load()
        await model.set(false)
        #expect(!model.isOn)
        #expect(model.message == .failed)
    }

    @Test func failedCheckIsAskedAgain() async {
        let asked = Counter()
        let support = PushSupport(
            switcher: FakeSwitch(), offersPush: { _ in asked.add(); return false }, askPermission: { true },
            registerForRemote: {})
        let anna = account()
        _ = await support.isAvailable(anna)
        _ = await support.isAvailable(anna)
        #expect(asked.count == 2)
    }

    @Test func availabilityIsAskedOncePerAccount() async {
        let asked = Counter()
        let support = PushSupport(
            switcher: FakeSwitch(), offersPush: { _ in asked.add(); return true }, askPermission: { true },
            registerForRemote: {})
        let anna = account()
        _ = await support.isAvailable(anna)
        _ = await support.isAvailable(anna)
        #expect(asked.count == 1)
    }
}
