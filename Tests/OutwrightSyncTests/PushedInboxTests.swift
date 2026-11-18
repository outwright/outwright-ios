// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

/// A push updates the Inbox of the account it is for, in the app's store, and says what came.
@Suite struct PushedInboxTests {
    private func pushed(_ h: Harness, subscription: String = "sub-1") -> PushedInbox {
        let account = h.account
        return PushedInbox(store: h.store, credentials: CredentialProvider(secrets: h.secrets), now: { fixedNow }) {
            $0 == subscription ? account : nil
        }
    }

    /// Mail dated now: older mail than an hour before the mark is never announced.
    private func fresh(_ subject: String) -> Data {
        mail(subject, date: fixedNow)
    }

    @Test func newMailIsStoredAndClaimed() async throws {
        let server = await standardServer()
        await server.deliver(fresh("before"), to: "INBOX")
        try await withHarness(server) { h in
            _ = try await synced(h)
            let update = pushed(h)
            #expect(await update.update(subscriptionID: "sub-1", budget: .seconds(10)).why == .nothingNew)
            await server.deliver(fresh("new one"), to: "INBOX")
            let (rows, why) = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            #expect(why == .found)
            #expect(rows.map(\.subject) == ["new one"])
            #expect(try h.rows(.inbox).map(\.subject) == ["before", "new one"])
        }
    }

    @Test func onlyThatAccountIsTouched() async throws {
        let other = await standardServer()
        let otherPort = try await other.start()
        defer { Task { await other.stop() } }
        let server = await standardServer()
        try await withHarness(server) { h in
            var second = Harness.account(imapPort: otherPort, smtpPort: otherPort)
            second.email = "other@example.org"
            try h.store.save(second)
            try h.secrets.setPassword(.init(FakeIMAPServer.password), for: second.id)
            _ = try await synced(h)
            await other.deliver(fresh("not for this push"), to: "INBOX")
            await server.deliver(fresh("for this push"), to: "INBOX")
            let update = pushed(h)
            _ = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            #expect(await other.sessionStarts.isEmpty)
            #expect(try h.store.folders(second.id).isEmpty)
        }
    }

    @Test func aSecondPushFindsNothing() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            _ = try await synced(h)
            let update = pushed(h)
            _ = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            await server.deliver(fresh("once"), to: "INBOX")
            #expect(await update.update(subscriptionID: "sub-1", budget: .seconds(10)).rows.count == 1)
            let again = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            #expect(again.rows.isEmpty)
            #expect(again.why == .nothingNew)
        }
    }

    @Test func anUnknownSubscriptionTouchesNothing() async throws {
        let server = await standardServer()
        await server.deliver(fresh("waiting"), to: "INBOX")
        try await withHarness(server) { h in
            let answer = await pushed(h).update(subscriptionID: "sub-unknown", budget: .seconds(10))
            #expect(answer.why == .unknownSubscription)
            #expect(answer.rows.isEmpty)
            #expect(await server.sessionStarts.isEmpty)
        }
    }

    @Test func aWrongPasswordSaysSignIn() async throws {
        try await withHarness { h in
            try h.secrets.setPassword(.init("wrong"), for: h.account.id)
            let answer = await pushed(h).update(subscriptionID: "sub-1", budget: .seconds(10))
            #expect(answer.why == .signInFailed)
            #expect(answer.rows.isEmpty)
        }
    }

    @Test func aHangingServerGivesUpWithinBudget() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            _ = try await synced(h)
            let update = pushed(h)
            _ = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            await server.deliver(fresh("slow"), to: "INBOX")
            // Far longer than the budget; generous margins, so a busy CI machine doesn't count.
            await server.delayFetches(.seconds(60))
            // The suspending clock: a Mac asleep mid-run is no wait.
            let start = SuspendingClock.now
            let answer = await update.update(subscriptionID: "sub-1", budget: .seconds(1))
            #expect(answer.why == .outOfTime)
            #expect(SuspendingClock.now - start < .seconds(20))
        }
    }

    @Test func aStoreWithoutFoldersStillAnswers() async throws {
        let server = await standardServer()
        await server.deliver(fresh("first"), to: "INBOX")
        try await withHarness(server) { h in
            let answer = await pushed(h).update(subscriptionID: "sub-1", budget: .seconds(10))
            let rows = try h.rows(.inbox)
            #expect(answer.why == .nothingNew)
            #expect(rows.map(\.subject) == ["first"])
        }
    }

    @Test func mailSeenInTheAppIsNotAnnounced() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            _ = try await synced(h)
            let update = pushed(h)
            _ = await update.update(subscriptionID: "sub-1", budget: .seconds(10))
            await server.deliver(fresh("seen in the app"), to: "INBOX")
            try await h.syncer().sync(try h.folder(.inbox).id)
            try h.store.moveNewMailMarks(now: fixedNow)
            #expect(await update.update(subscriptionID: "sub-1", budget: .seconds(10)).why == .nothingNew)
        }
    }
}
