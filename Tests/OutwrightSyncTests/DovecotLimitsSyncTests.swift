// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

/// The app within Dovecot's limit of 10 connections per user and address: one account holds its
/// main connection and its IDLE, and one being replaced (a network change, a trip to the
/// background) is let go as the new one comes, so it never nears the limit.
@Suite struct DovecotLimitsSyncTests {
    @Test func aDaysUseStaysWellUnderTheConnectionLimit() async throws {
        let imap = await standardServer()
        await imap.keepDovecotLimits()
        for index in 0..<30 {
            _ = await imap.deliver(mail("Mail \(index)"), to: "INBOX")
        }
        try await withHarness(imap) { h in
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, now: { fixedNow })
            await coordinator.refreshAll()
            await coordinator.startForeground()
            await h.imap.waitUntilIdling()
            await coordinator.prefetchInboxBodies(onWiFi: true)
            _ = await coordinator.searchServer("Mail")
            for _ in 0..<3 {
                await coordinator.networkChanged()
                await h.imap.waitUntilIdling()
                await coordinator.stopForeground()
                await coordinator.startForeground()
                await h.imap.waitUntilIdling()
                await coordinator.refreshAll()
            }
            await coordinator.stopForeground()
        }
        #expect(await imap.limitRefusals == 0)
        #expect(await imap.peakSignedIn <= 3)
    }
}
