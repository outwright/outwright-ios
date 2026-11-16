// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightIMAP
import OutwrightModel
import OutwrightNet
import OutwrightSMTP
import OutwrightStore
import Testing

@testable import OutwrightSync

/// The harness's account signing in with Microsoft tokens from a fake token endpoint.
struct OAuthAccountHarness {
    let mail: Harness
    let oauth: OAuthHarness
    let account: Account
    let credentials: CredentialProvider

    func syncer() -> AccountSyncer {
        AccountSyncer(account: account, store: mail.store, credentials: credentials, now: { fixedNow })
    }
}

/// `seed`: the sign-in's access token is held (as right after signing in) and both fakes
/// accept it.
func withOAuthAccount(
    _ imap: FakeIMAPServer? = nil, seed: Bool = true, provider: ProviderID = testOAuthProvider,
    _ body: (OAuthAccountHarness) async throws -> Void
) async throws {
    try await withHarness(imap) { h in
        try await withOAuth(account: h.account.id) { o in
            var account = h.account
            account.auth = .oauth
            account.provider = provider
            account.calendarVia = .graph
            account.contactsVia = .graph
            try h.store.save(account)
            try h.secrets.remove(for: account.id)
            let credentials = CredentialProvider(secrets: o.secrets, tokens: [provider: o.oauth], now: o.now)
            if seed {
                try await credentials.store(o.tokens, for: account.id, provider: account.provider)
                await h.imap.acceptToken(o.tokens.accessToken.reveal())
                await h.smtp.acceptToken(o.tokens.accessToken.reveal())
            }
            try await body(OAuthAccountHarness(mail: h, oauth: o, account: account, credentials: credentials))
        }
    }
}

@Suite struct MicrosoftSyncTests {
    @Test func microsoftAccountSyncsInbox() async throws {
        let server = await standardServer()
        await server.deliver(mail("from the tenant"), to: "INBOX")
        try await withOAuthAccount(server) { m in
            let syncer = m.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try m.mail.folder(.inbox).id)
            #expect(try m.mail.rows(.inbox).map(\.subject) == ["from the tenant"])
            let attempts = await server.tokenAttempts
            #expect(!attempts.isEmpty)
            #expect(attempts.allSatisfy { $0.accepted && $0.user == FakeIMAPServer.user })
        }
    }

    @Test func microsoftAccountSendsMail() async throws {
        try await withOAuthAccount { m in
            let syncer = m.syncer()
            try await syncer.syncFolders()
            try await syncer.sync(try m.mail.folder(.inbox).id)
            let id = try localDraft(m.mail, uid: 0, data: try draftData())
            try m.mail.store.apply(.send(draftID: id))
            try await syncer.runActions()
            #expect(await m.mail.smtp.received.count == 1)
            let attempts = await m.mail.smtp.tokenAttempts
            #expect(attempts.count == 1)
            #expect(attempts.allSatisfy { $0.accepted })
            #expect(try m.mail.store.pendingActions().isEmpty)
        }
    }

    @Test func rejectedTokenRefreshesOnce() async throws {
        try await withOAuthAccount { m in
            // The held token looked valid but the server takes only a newer one.
            await m.mail.imap.acceptToken("fresh-access")
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let before = await m.oauth.server.requests
            try await m.syncer().syncFolders()
            #expect(await m.mail.imap.tokenAttempts.map(\.accepted) == [false, true])
            #expect(await m.oauth.server.requests == before + 1)
        }
    }

    @Test func aSecondRejectionFailsWithoutAThirdTry() async throws {
        try await withOAuthAccount { m in
            await m.mail.imap.acceptToken("a token never issued")
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let before = await m.oauth.server.requests
            await #expect(throws: SyncError.imap(.authenticationFailed)) { try await m.syncer().syncFolders() }
            #expect(await m.mail.imap.tokenAttempts.map(\.accepted) == [false, false])
            #expect(await m.oauth.server.requests == before + 1)
        }
    }

    @Test func rejectedSendTokenRefreshesOnce() async throws {
        try await withOAuthAccount { m in
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

    @Test func revokedSignInStopsSyncAsNeedingSignIn() async throws {
        try await withOAuthAccount(seed: false) { m in
            await m.mail.imap.acceptToken("whatever")
            await m.oauth.server.revoke(try #require(m.oauth.tokens.refreshToken).reveal())
            let syncer = m.syncer()
            await #expect(throws: SyncError.needsSignIn(m.account.id)) { try await syncer.syncFolders() }
            let asked = await m.oauth.server.requests
            await #expect(throws: SyncError.needsSignIn(m.account.id)) { try await syncer.syncFolders() }
            #expect(await m.oauth.server.requests == asked)
            #expect(await m.mail.imap.tokenAttempts.isEmpty)
        }
    }

    @Test func serverWithoutXOAUTH2IsAClearError() async throws {
        try await withOAuthAccount(seed: false) { m in
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            await #expect(throws: SyncError.noTokenSignIn) { try await m.syncer().syncFolders() }
        }
    }

    @Test func twoCallersRefusedTheSameTokenRefreshOnce() async throws {
        try await withOAuthAccount { m in
            await m.mail.imap.acceptToken("fresh-access")
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let source = try m.credentials.tokenSource(for: m.account.id, provider: testOAuthProvider)
            let old = try await source.accessToken()
            let before = await m.oauth.server.requests
            _ = await source.invalidate(old)
            let renewed = try await source.accessToken()
            // A second caller, rejected with the same old token, must not wipe the new one.
            _ = await source.invalidate(old)
            let again = try await source.accessToken()
            #expect(renewed.reveal() == "fresh-access")
            #expect(again.reveal() == renewed.reveal())
            #expect(await m.oauth.server.requests == before + 1)
        }
    }

    @Test func aServerRejectingEveryTokenIsNotRedeemedAgainWithinAMinute() async throws {
        try await withOAuthAccount { m in
            await m.mail.imap.acceptToken("a token never issued")
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let before = await m.oauth.server.requests
            for _ in 0..<3 {
                await #expect(throws: SyncError.imap(.authenticationFailed)) { try await m.syncer().syncFolders() }
            }
            #expect(await m.oauth.server.requests <= before + 1)
            // Once the renewed token is a minute old, a rejection renews again.
            m.oauth.offset.value.withLock { $0 = 61 }
            await m.oauth.server.script([OAuthHarness.answer(access: "later-access")])
            await #expect(throws: SyncError.imap(.authenticationFailed)) { try await m.syncer().syncFolders() }
            #expect(await m.oauth.server.requests == before + 2)
        }
    }

    @Test func smtpWithoutXOAUTH2NeedsNoTokenSignInAndNoRefresh() async throws {
        try await withOAuthAccount(seed: false) { m in
            await m.oauth.server.script([OAuthHarness.answer(access: "fresh-access")])
            let endpoint = ServerEndpoint(host: "127.0.0.1", port: m.account.smtp.port, security: .plainLoopbackOnly)
            let account = m.account
            await #expect(throws: SyncError.noTokenSignIn) {
                try await m.credentials.withSMTP(for: account) { credential throws(SMTPError) in
                    try await SMTPClient.signIn(via: endpoint, user: account.user, credential: credential)
                }
            }
            let afterFirst = await m.oauth.server.requests
            // The one request is the first token; the refusal did not cause another.
            await #expect(throws: SyncError.noTokenSignIn) {
                try await m.credentials.withSMTP(for: account) { credential throws(SMTPError) in
                    try await SMTPClient.signIn(via: endpoint, user: account.user, credential: credential)
                }
            }
            #expect(await m.oauth.server.requests == afterFirst)
        }
    }

    @Test func syncsOfOneAccountShareOneRefresh() async throws {
        try await withOAuthAccount(seed: false) { m in
            await m.mail.imap.acceptToken("shared-access")
            await m.oauth.server.script([OAuthHarness.answer(access: "shared-access")])
            let before = await m.oauth.server.requests
            // Two syncers, as after a changed connection, and a coordinator's copy of the provider.
            let first = m.syncer()
            let second = AccountSyncer(
                account: m.account, store: m.mail.store, credentials: m.credentials, now: { fixedNow })
            async let one: Void = first.syncFolders()
            async let two: Void = second.syncFolders()
            _ = try await (one, two)
            #expect(await m.oauth.server.requests == before + 1)
        }
    }

    @Test func coordinatorSyncsAMicrosoftAccount() async throws {
        let server = await standardServer()
        await server.deliver(mail("via the coordinator"), to: "INBOX")
        try await withOAuthAccount(server, seed: false) { m in
            await server.acceptToken("shared-access")
            // The mail token, then the Graph one (the scripted refresh token is not the fake's own).
            await m.oauth.server.script([
                OAuthHarness.answer(access: "shared-access"), OAuthHarness.answer(access: "graph-access"),
            ])
            // Its contacts go to a fake Graph: a test never reaches Microsoft.
            let graph = FakeGraphServer()
            let graphBase = try await graph.start()
            let coordinator = SyncCoordinator(
                store: m.mail.store, secrets: m.oauth.secrets, tokens: [testOAuthProvider: m.oauth.oauth], graphBases: [testOAuthProvider: graphBase])
            await coordinator.refreshAll()
            await graph.stop()
            #expect(await coordinator.lastErrors[m.account.id] == nil)
            let subjects = try m.mail.rows(.inbox).map(\.subject)
            #expect(subjects == ["via the coordinator"])
        }
    }

    /// A Microsoft account's calendar comes through Graph with its mail and contacts.
    @Test func coordinatorSyncsAMicrosoftCalendar() async throws {
        let server = await standardServer()
        try await withOAuthAccount(server, seed: false) { m in
            await server.acceptToken("shared-access")
            await m.oauth.server.script([
                OAuthHarness.answer(access: "shared-access"), OAuthHarness.answer(access: "graph-access"),
            ])
            let graph = FakeGraphServer()
            let graphBase = try await graph.start()
            let home = await graph.addCalendar("Calendar", isDefault: true)
            await graph.putEvent(graphEvent("Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00"), in: home)
            let coordinator = SyncCoordinator(
                store: m.mail.store, secrets: m.oauth.secrets, tokens: [testOAuthProvider: m.oauth.oauth], now: { graphNow },
                phoneZone: { stockholm }, graphBases: [testOAuthProvider: graphBase])
            await coordinator.refreshAll()
            await graph.stop()
            #expect(await coordinator.lastErrors[m.account.id] == nil)
            let held = try m.mail.store.occurrences(
                from: graphNow, to: graphNow.addingTimeInterval(30 * 86_400), in: nil)
            #expect(held.map(\.occurrence.details.title) == ["Lunch"])
        }
    }

    @Test func passwordAccountsUnchanged() async throws {
        let server = await standardServer()
        await server.deliver(mail("by password"), to: "INBOX")
        try await withHarness(server) { h in
            let credentials = CredentialProvider(secrets: h.secrets)
            let syncer = AccountSyncer(account: h.account, store: h.store, credentials: credentials, now: { fixedNow })
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            #expect(try h.rows(.inbox).map(\.subject) == ["by password"])
            #expect(await server.tokenAttempts.isEmpty)
        }
    }
}
