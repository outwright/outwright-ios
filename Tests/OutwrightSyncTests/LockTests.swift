// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

@Suite struct LockTests {
    /// An operation waiting for the account's turn gives up at once when its task is cancelled,
    /// and leaves the turn to whoever comes next.
    @Test func aCancelledWaitForTheAccountEndsAtOnce() async throws {
        let server = await standardServer()
        await server.deliver(mail("Slow", id: "slow@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            let inbox = try h.folder(.inbox).id
            await server.delayFetches(.seconds(3))
            let holder = Task { try await syncer.sync(inbox) }
            try await Task.sleep(for: .milliseconds(300))
            let waiter = Task { try await syncer.syncFolders() }
            try await Task.sleep(for: .milliseconds(200))
            let start = SuspendingClock.now
            waiter.cancel()
            _ = await waiter.result
            #expect(SuspendingClock.now - start < .seconds(1))
            try await holder.value
            await server.delayFetches(.zero)
            try await syncer.syncFolders()
        }
    }

    /// A calendar operation cancelled while it waits for the account's turn never runs, and
    /// leaves the turn with whoever holds it.
    @Test func aCalendarOperationCancelledWhileWaitingNeverRuns() async throws {
        try await withCalendars { h in
            let lock = AccountLock()
            let syncer = CalendarSyncer(
                account: h.account, store: h.store, secrets: h.secrets, lock: lock,
                session: URLSession(configuration: .ephemeral), now: { fixedNow }, phoneZone: { stockholm })
            #expect(await lock.acquire())
            let ran = Mutex(false)
            let waiter = Task { try await syncer.exclusive { ran.withLock { $0 = true } } }
            try await Task.sleep(for: .milliseconds(200))
            waiter.cancel()
            await #expect(throws: SyncError.self) { try await waiter.value }
            #expect(!ran.withLock { $0 })
            // The turn is still the holder's: a newcomer waits for it.
            let got = Mutex(false)
            let next = Task {
                let turn = await lock.acquire()
                got.withLock { $0 = true }
                return turn
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!got.withLock { $0 })
            await lock.release()
            #expect(await next.value)
            await lock.release()
        }
    }

    /// A Graph calendar operation cancelled while it waits for the account's turn never runs, and
    /// leaves the turn with whoever holds it.
    @Test func aGraphOperationCancelledWhileWaitingNeverRuns() async throws {
        try await withGraphContacts { h in
            let lock = AccountLock()
            let syncer = GraphCalendarSyncer(
                account: h.account, store: h.store, credentials: h.microsoft.credentials, lock: lock, base: h.base,
                session: URLSession(configuration: .ephemeral), now: { graphNow }, phoneZone: { stockholm })
            #expect(await lock.acquire())
            let ran = Mutex(false)
            let waiter = Task { try await syncer.exclusive { ran.withLock { $0 = true } } }
            try await Task.sleep(for: .milliseconds(200))
            waiter.cancel()
            await #expect(throws: SyncError.self) { try await waiter.value }
            #expect(!ran.withLock { $0 })
            let got = Mutex(false)
            let next = Task {
                let turn = await lock.acquire()
                got.withLock { $0 = true }
                return turn
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!got.withLock { $0 })
            await lock.release()
            #expect(await next.value)
            await lock.release()
        }
    }

    /// A connection still being opened when the account is disconnected is closed, not kept
    /// for an IDLE that nothing will end.
    @Test func aConnectionOpenedDuringADisconnectIsNotKept() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let syncer = h.syncer()
            try await syncer.syncFolders()
            await server.delayLogins(.milliseconds(500))
            let before = await server.sessionStarts.count
            let idling = Task { try await syncer.idleInbox() }
            // The IDLE connection has reached the server and waits on its slow sign-in: the
            // disconnect comes while it is being opened, however slowly the task started.
            #expect(await eventually { await server.sessionStarts.count > before })
            await syncer.disconnect()
            #expect(await eventually { await server.openSessions == 0 })
            idling.cancel()
            await #expect(throws: SyncError.self) { _ = try await idling.value }
        }
    }

    /// A refresh cut short keeps what the account last failed with: it did not get far enough to
    /// know better.
    @Test func aCancelledRefreshKeepsTheEarlierError() async throws {
        let server = await standardServer()
        await server.deliver(mail("New"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = SyncCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.record(h.account.id, .noPassword)
            await server.delayLogins(.milliseconds(500))
            let refresh = Task { await coordinator.refreshAll() }
            try await Task.sleep(for: .milliseconds(200))
            refresh.cancel()
            await refresh.value
            #expect(await coordinator.lastErrors[h.account.id] == .noPassword)
        }
    }

    /// A refresh cancelled while it waits for the account's turn ends at once and records
    /// nothing: the stop is no failure of the account, and what it last failed with stays.
    @Test func aRefreshCancelledWhileWaitingRecordsNothing() async throws {
        let server = await standardServer()
        await server.deliver(mail("Slow"), to: "INBOX")
        try await withHarness(server) { h in
            let coordinator = SyncCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await coordinator.record(h.account.id, .noPassword)
            let row = try #require(try h.rows(.inbox).first)
            await server.delayFetches(.seconds(3))
            let holder = Task { try await coordinator.fetchBody(row.id) }
            try await Task.sleep(for: .milliseconds(300))
            let refresh = Task { await coordinator.refreshAll() }
            try await Task.sleep(for: .milliseconds(200))
            let start = SuspendingClock.now
            refresh.cancel()
            await refresh.value
            #expect(SuspendingClock.now - start < .seconds(1))
            #expect(await coordinator.lastErrors[h.account.id] == .noPassword)
            try await holder.value
        }
    }

    /// One failure to reach the server (the network not back yet when the app comes to the front)
    /// isn't shown, nor does it hide what was: the retry decides. A second in a row is shown.
    @Test func oneFailureToReachTheServerIsNotShown() async throws {
        try await withHarness { h in
            let id = h.account.id
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.record(id, .imap(.net(.timeout)))
            #expect(await coordinator.lastErrors[id] == nil)
            await coordinator.record(id, .smtp(.net(.timeout)))
            #expect(await coordinator.lastErrors[id] == .smtp(.net(.timeout)))
            await coordinator.record(id, nil)
            await coordinator.record(id, .imap(.net(.timeout)))
            #expect(await coordinator.lastErrors[id] == nil)
            await coordinator.record(id, nil)
            await coordinator.record(id, .noPassword)
            await coordinator.record(id, .imap(.net(.timeout)))
            #expect(await coordinator.lastErrors[id] == .noPassword)
        }
    }

    /// A failure to reach the server before the app went to the back doesn't count with the first
    /// one after it comes to the front.
    @Test func aFailureToReachTheServerBeforeTheFrontDoesNotCount() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            let id = h.account.id
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.record(id, .imap(.net(.timeout)))
            await server.delayLogins(.seconds(2))
            await coordinator.startForeground()
            await coordinator.record(id, .imap(.net(.timeout)))
            #expect(await coordinator.lastErrors[id] == nil)
            await coordinator.stopForeground()
        }
    }

    /// The bodies fetched ahead on Wi-Fi are no reason to say the server can't be reached: the
    /// watcher, which runs beside them as the app comes to the front, decides that.
    @Test func aPrefetchThatCannotReachTheServerIsNotCounted() async throws {
        let server = await standardServer()
        await server.deliver(mail("no body yet"), to: "INBOX")
        try await withHarness(server) { h in
            let id = h.account.id
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await server.stop()
            await coordinator.record(id, .imap(.net(.timeout)))
            await coordinator.prefetchInboxBodies(onWiFi: true)
            #expect(await coordinator.lastErrors[id] == nil)
        }
    }

    /// A watcher that has synced and is idling clears what the account last failed with: the
    /// banner doesn't say the server is unreachable while the IDLE runs its time.
    @Test func aWatcherThatIsIdlingClearsTheEarlierError() async throws {
        try await withHarness { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.record(h.account.id, .imap(.net(.timeout)))
            await coordinator.record(h.account.id, .imap(.net(.timeout)))
            #expect(await coordinator.lastErrors[h.account.id] != nil)
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            #expect(await eventually { await coordinator.lastErrors[h.account.id] == nil })
            await coordinator.stopForeground()
        }
    }

    /// A watched account that keeps failing is tried again after a wait that doubles up to the
    /// cap (here 400 ms, then 800 ms and no longer). Each wait is measured from the server's refusal
    /// to the next connection, so slow tries on a loaded machine don't count towards it.
    @Test func reconnectsWaitLongerEachTimeUpToTheCap() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            try h.secrets.setPassword(Secret("wrong"), for: h.account.id)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, backoff: .milliseconds(400) ... .milliseconds(800))
            await coordinator.startForeground()
            #expect(await eventually { await server.sessionStarts.count >= 5 })
            await coordinator.stopForeground()
            let starts = await server.sessionStarts
            let refusals = await server.loginRefusals
            let waits = zip(starts.dropFirst(), refusals).map { $0 - $1 }
            try #require(waits.count >= 4)
            // Load only ever lengthens a wait, so the bounds that hold are: no wait is shorter
            // than its backoff, and none grows past what the cap allows.
            // Doubled: the first waits at least 400 ms, the second at least 800 ms.
            #expect(waits[0] >= .milliseconds(400), "\(waits)")
            #expect(waits[1] >= .milliseconds(800), "\(waits)")
            // Capped: the fourth stays near 800 ms, where doubling on would have made it 3.2 s.
            #expect(waits[3] < .milliseconds(1600), "\(waits)")
            #expect(await coordinator.lastErrors[h.account.id] == .imap(.authenticationFailed))
        }
    }

    /// A calendar operation cancelled while it waits for the account's turn gets none, and never
    /// frees the turn another operation holds.
    @Test func aCancelledCalendarWaitLeavesTheTurnWithItsHolder() async throws {
        try await withCalendars { h in
            let lock = AccountLock()
            let calendar = CalendarSyncer(
                account: h.account, store: h.store, secrets: h.secrets, lock: lock,
                session: URLSession(configuration: .ephemeral), now: { fixedNow }, phoneZone: { stockholm })
            #expect(await lock.acquire())
            let waiter = Task { try await calendar.exclusive { () async throws(SyncError) in true } }
            try await Task.sleep(for: .milliseconds(200))
            waiter.cancel()
            await #expect(throws: SyncError.self) { _ = try await waiter.value }
            // Still held: the next in line waits until the holder lets go.
            let turns = TurnCount()
            let next = Task {
                let got = await lock.acquire()
                await turns.add()
                return got
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(await turns.count == 0)
            await lock.release()
            #expect(await next.value)
            #expect(await turns.count == 1)
            await lock.release()
        }
    }
}

private actor TurnCount {
    var count = 0
    func add() { count += 1 }
}
