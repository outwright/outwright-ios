// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import Testing

@testable import OutwrightSync

/// Sync decides by protocol (OAuth, Graph), never by which provider an account is with.
@Suite struct ProviderProtocolTests {
    static let other = ProviderID(raw: "example-oauth")

    @Test func oauthAccountWithoutRefresherCannotSignIn() async throws {
        try await withHarness { h in
            var account = h.account
            account.auth = .oauth
            account.provider = Self.other
            let credentials = CredentialProvider(secrets: h.secrets)
            await #expect(throws: SyncError.needsSignIn(account.id)) {
                try await credentials.smtpCredential(for: account)
            }
        }
    }

    @Test func oauthSendRetriesOnceAfterRefusalForAnyProvider() async throws {
        try await withOAuthAccount(provider: Self.other) { m in
            let syncer = m.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try m.mail.folder(.inbox).id)
            await m.mail.smtp.acceptToken("fresh-access")
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let id = try localDraft(m.mail, uid: 0, data: try draftData())
            try m.mail.store.apply(.send(draftID: id))
            try await syncer.runActions()
            #expect(await m.mail.smtp.received.count == 1)
            #expect(await m.mail.smtp.tokenAttempts.map(\.accepted) == [false, true])
        }
    }

    @Test func graphCalendarChosenByCalendarVia() async throws {
        let server = await standardServer()
        try await withOAuthAccount(server, seed: false, provider: Self.other) { m in
            await server.acceptToken("shared-access")
            await m.oauth.server.script([
                OAuthHarness.answer(access: "shared-access"), OAuthHarness.answer(access: "graph-access"),
            ])
            let graph = FakeGraphServer()
            let graphBase = try await graph.start()
            let home = await graph.addCalendar("Calendar", isDefault: true)
            await graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            let coordinator = SyncCoordinator(
                store: m.mail.store, secrets: m.oauth.secrets, tokens: [Self.other: m.oauth.oauth], now: { graphNow },
                phoneZone: { stockholm }, graphBases: [Self.other: graphBase])
            await coordinator.refreshAll()
            await graph.stop()
            #expect(await coordinator.lastErrors[m.account.id] == nil)
            let held = try m.mail.store.occurrences(
                from: graphNow, to: graphNow.addingTimeInterval(30 * 86_400), in: nil)
            #expect(held.map(\.occurrence.details.title) == ["Lunch"])
        }
    }

    @Test func aChangedProtocolGetsANewCalendarSyncer() async throws {
        try await withHarness { h in
            var account = h.account
            account.provider = Self.other
            account.calendarVia = .graph
            try h.store.save(account)
            let base = try #require(URL(string: "https://graph.example.org/v1.0/"))
            let coordinator = SyncCoordinator(
                store: h.store, secrets: h.secrets, graphBases: [Self.other: base])
            #expect(await coordinator.calendarSyncer(for: account.id) is GraphCalendarSyncer)
            account.calendarVia = .calDAV
            try h.store.save(account)
            #expect(await coordinator.calendarSyncer(for: account.id) is CalendarSyncer)
        }
    }

    @Test func graphWithoutAGraphAddressGetsNoSyncer() async throws {
        try await withHarness { h in
            var account = h.account
            account.provider = Self.other
            account.calendarVia = .graph
            account.contactsVia = .graph
            try h.store.save(account)
            let coordinator = SyncCoordinator(store: h.store, secrets: h.secrets)
            #expect(await coordinator.calendarSyncer(for: account.id) == nil)
            #expect(await coordinator.contactSyncer(for: account.id) == nil)
        }
    }
}
