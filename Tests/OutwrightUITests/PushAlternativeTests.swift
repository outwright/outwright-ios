// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI
import Testing

@testable import OutwrightUI

/// A build's alternative to push from the server, as the switch sees it.
@MainActor private final class FakeAlternative: PushAlternative {
    let offered: Bool
    let inUse: Bool

    init(offered: Bool = true, inUse: Bool = false) {
        self.offered = offered
        self.inUse = inUse
    }

    func offers(_ account: Account) -> Bool { offered }
    func isInUse(_ account: AccountID) async -> Bool { inUse }
    func note(for account: Account) -> String { "" }
    func row(for account: Account) -> AnyView { AnyView(EmptyView()) }
}

/// When the Notifications switch shows the build's alternative to push from the server: wherever
/// push from the server is not on, and wherever the account already uses the alternative.
@MainActor @Suite struct PushAlternativeTests {
    private func model(
        _ switcher: FakeSwitch = FakeSwitch(), on anna: Account = account(), offersPush: Bool = true,
        pushIncluded: Bool = true,
        dropped: Bool = false, alternative: FakeAlternative = FakeAlternative()
    ) -> NotificationsToggleModel {
        let support = PushSupport(
            switcher: switcher, offersPush: { _ in offersPush }, askPermission: { true }, registerForRemote: {},
            dropped: { _ in dropped })
        return NotificationsToggleModel(
            account: anna, support: support, local: FakeLocal(), pushIncluded: pushIncluded,
            alternative: alternative)
    }

    @Test func pushNotOnShowsIt() async {
        let model = model()
        await model.load()
        #expect(model.showsAlternative)
    }

    @Test func pushThatFailedEarlierShowsItOnTheNextVisit() async {
        let switcher = FakeSwitch(failure: .notSetUp)
        let anna = account()
        let first = model(switcher, on: anna)
        await first.load()
        await first.set(true)
        let next = model(switcher, on: anna)
        await next.load()
        #expect(next.showsAlternative)
    }

    @Test func serverRefusedShowsIt() async {
        let model = model(FakeSwitch(failure: .serverRefused))
        await model.load()
        await model.set(true)
        #expect(model.showsAlternative)
    }

    @Test func droppedPushShowsIt() async {
        let model = model(dropped: true)
        await model.load()
        #expect(model.message == .dropped)
        #expect(model.showsAlternative)
    }

    @Test func localFallbackShowsIt() async {
        let model = model(offersPush: false)
        await model.load()
        await model.set(true)
        #expect(model.isLocal)
        #expect(model.showsAlternative)
    }

    @Test func pushOnHidesIt() async {
        let model = model()
        await model.load()
        await model.set(true)
        #expect(!model.showsAlternative)
    }

    @Test func inUseKeepsItWithPushOn() async {
        let model = model(alternative: FakeAlternative(inUse: true))
        await model.load()
        await model.set(true)
        #expect(model.showsAlternative)
    }

    @Test func pushNotIncludedHidesIt() async {
        let model = model(pushIncluded: false)
        await model.load()
        #expect(!model.showsAlternative)
    }

    @Test func inUseKeepsItWherePushIsNoLongerIncluded() async {
        let model = model(pushIncluded: false, alternative: FakeAlternative(inUse: true))
        await model.load()
        #expect(model.showsAlternative)
    }

    @Test func inUseWithPushOnIsNotForWantOfPush() async {
        let model = model(alternative: FakeAlternative(inUse: true))
        await model.load()
        await model.set(true)
        #expect(!model.missesPush)
    }

    @Test func switchOffIsForWantOfPush() async {
        let model = model(alternative: FakeAlternative(inUse: true))
        await model.load()
        #expect(model.missesPush)
    }

    @Test func notOfferedIsNeverShown() async {
        let model = model(alternative: FakeAlternative(offered: false, inUse: true))
        await model.load()
        #expect(!model.showsAlternative)
    }
}
