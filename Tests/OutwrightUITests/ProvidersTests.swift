// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Observable
final class StubSignIn: ProviderSignIn {
    var isSigningIn = false
    var signedInAgain: [AccountID] = []
    var hints: [String?] = []
    func addAccount(hint: String?) async throws(ProviderSignInError) -> Account {
        hints.append(hint)
        throw .cancelled
    }
    func signInAgain(_ account: Account) async throws(ProviderSignInError) { signedInAgain.append(account.id) }
}

@MainActor
struct StubProvider: AccountProvider {
    static let stubID = ProviderID(raw: "stub")
    let id = StubProvider.stubID
    let tokens: (any TokenRefreshing)? = nil
    let graphBase: URL? = nil
    let addTitle = "Stub Mail"
    let addNote: String? = nil
    let addIdentifier = "addAccount.stub"
    let signInHeader = "Stub sign-in"
    let made = StubSignIn()
    /// The addresses this provider says are its own.
    var claimed: Set<String> = []
    /// How long the provider takes to answer whether an address is its own.
    var answersAfter: Duration = .zero
    func signIn(app: AppModel) -> (any ProviderSignIn)? { made }
    func claims(_ address: String, resolver: any DoHResolving) async -> Bool {
        if answersAfter > .zero { try? await Task.sleep(for: answersAfter) }
        return claimed.contains(address)
    }
}

@MainActor
@Suite struct ProvidersTests {
    private func app(_ providers: [any AccountProvider]) throws -> (AppModel, Mailbox) {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        var modules = Modules()
        modules.providers = providers
        app.modules = modules
        return (app, box)
    }

    @Test func addAccountListsRegisteredProviders() throws {
        #expect(try app([StubProvider()]).0.addableProviders.map(\.provider.id) == [StubProvider.stubID])
        #expect(try app([]).0.addableProviders.isEmpty)
    }

    /// An address a provider says is its own goes to that provider's sign-in; any other to the
    /// owner's own server.
    @Test func addressGoesToTheProviderClaimingIt() async throws {
        let stub = StubProvider(claimed: ["anna@stub.example"])
        let (app, _) = try app([stub])
        let resolver = FixedDoH(answers: [:])
        let entries = app.addableProviders
        // Which provider, not how fast (slowClaimIsNotWaitedFor): a loaded test run may take seconds.
        let limit = Duration.seconds(60)
        #expect(
            await AppModel.signIn(claiming: "anna@stub.example", among: entries, resolver: resolver, within: limit)
                === stub.made)
        #expect(
            await AppModel.signIn(claiming: "anna@example.org", among: entries, resolver: resolver, within: limit)
                == nil)
        #expect(await AppModel.signIn(claiming: "anna@stub.example", among: [], resolver: resolver) == nil)
    }

    /// A provider slow to answer does not hold up the own server's lookup.
    @Test func slowClaimIsNotWaitedFor() async throws {
        // Far beyond the limit, so a busy main actor in a full test run never makes it look waited for.
        let stub = StubProvider(claimed: ["anna@stub.example"], answersAfter: .seconds(120))
        let (app, _) = try app([stub])
        // The suspending clock: a Mac asleep mid-run is no wait.
        let started = SuspendingClock.now
        let claimed = await AppModel.signIn(
            claiming: "anna@stub.example", among: app.addableProviders, resolver: FixedDoH(answers: [:]),
            within: .milliseconds(50))
        #expect(claimed == nil)
        #expect(SuspendingClock.now - started < .seconds(60))
    }

    @Test func accountOfMissingProviderIsUnavailable() throws {
        let (app, _) = try app([StubProvider()])
        var account = Account(
            id: AccountID(), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "mail.example.org", port: 993, security: "tls"),
            smtp: MailEndpoint(host: "mail.example.org", port: 465, security: "tls"),
            user: "anna", signature: "", sortOrder: 0)
        #expect(!app.isUnavailable(account))
        account.provider = StubProvider.stubID
        #expect(!app.isUnavailable(account))
        account.provider = ProviderID(raw: "gone")
        #expect(app.isUnavailable(account))
    }

    @Test func signInAgainOnlyForItsProvider() throws {
        let stub = StubProvider()
        let (app, _) = try app([stub])
        var account = Account(
            id: AccountID(), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
            imap: MailEndpoint(host: "mail.example.org", port: 993, security: "tls"),
            smtp: MailEndpoint(host: "mail.example.org", port: 465, security: "tls"),
            user: "anna", signature: "", sortOrder: 0, auth: .oauth)
        #expect(app.signIn(for: account) == nil)
        account.provider = StubProvider.stubID
        #expect(app.signIn(for: account) === stub.made)
    }

    /// Mail, events and contacts are never offered on an account this build cannot sync.
    @Test func unavailableAccountIsNotOfferedForWriting() throws {
        let (app, mailbox) = try app([StubProvider()])
        var box = mailbox
        let kept = try box.addAccount("kept@example.org")
        var gone = try box.addAccount("gone@example.org")
        gone.provider = ProviderID(raw: "gone")
        try box.store.save(gone)
        app.reloadAccounts()
        #expect(app.accounts.count == 2)
        #expect(app.writableAccounts.map { $0.id } == [kept.id])
    }
}
