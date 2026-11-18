// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

/// A module that reports what it is given, per account address.
@MainActor private final class FakeAttention: AccountAttention {
    var reports: [AttentionItem] = []
    func items(for accounts: [Account]) async -> [AttentionItem] { reports }
}

/// A module whose first report waits until released, and says "old"; every later one says "new" at once.
@MainActor private final class GatedAttention: AccountAttention {
    let account: AccountID
    var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    init(account: AccountID) { self.account = account }
    func items(for accounts: [Account]) async -> [AttentionItem] {
        calls += 1
        guard calls == 1 else {
            return [AttentionItem(id: "new", account: account, text: "", action: .accountSettings)]
        }
        await withCheckedContinuation { gate = $0 }
        return [AttentionItem(id: "old", account: account, text: "", action: .accountSettings)]
    }
    func release() {
        gate?.resume()
        gate = nil
    }
}

/// A sign-in that runs until released.
@MainActor private final class SlowSignIn: ProviderSignIn {
    var isSigningIn = false
    var started = 0
    private var gate: CheckedContinuation<Void, Never>?
    func addAccount(hint: String?) async throws(ProviderSignInError) -> Account { throw .cancelled }
    func signInAgain(_ account: Account) async throws(ProviderSignInError) {
        started += 1
        await withCheckedContinuation { gate = $0 }
    }
    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor private struct SlowProvider: AccountProvider {
    let id = ProviderID(raw: "slow")
    let tokens: (any TokenRefreshing)? = nil
    let graphBase: URL? = nil
    let addTitle = "Slow"
    let addNote: String? = nil
    let addIdentifier = "addAccount.slow"
    let signInHeader = "Slow"
    let made: SlowSignIn
    func signIn(app: AppModel) -> (any ProviderSignIn)? { made }
    func claims(_ address: String, resolver: any DoHResolving) async -> Bool { false }
}

/// Lets other tasks on the main actor run until `done` holds (or a bound is reached).
@MainActor private func settle(until done: () -> Bool) async {
    for _ in 0..<1000 where !done() {
        await Task.yield()
    }
}

@MainActor @Suite struct AccountAttentionTests {
    private func item(_ id: String, _ account: AccountID) -> AttentionItem {
        AttentionItem(id: id, account: account, text: "Something", action: .accountSettings)
    }

    /// "A message wasn't sent" goes to that account's Drafts, not to settings.
    @Test func notSentProblemOpensDrafts() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let bert = try box.addAccount("bert@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.selectedTab = .contacts
        let item = AttentionItem(AccountProblem(account: bert, problem: .notSent))
        #expect(item.action == .drafts)
        app.act(on: item)
        #expect(app.scope == .folder(try box.folder(bert, .drafts).id))
        #expect(app.selectedTab == .mail)
        #expect(!app.isShowingSettings)
    }

    /// Every other sync problem opens the account's settings; a lost sign-in signs in again.
    @Test func syncProblemsChooseTheirAction() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        #expect(AttentionItem(AccountProblem(account: anna, problem: .signInAgain)).action == .signInAgain)
        #expect(AttentionItem(AccountProblem(account: anna, problem: .unreachable)).action == .accountSettings)
        #expect(AttentionItem(AccountProblem(account: anna, problem: .noPassword)).action == .accountSettings)
    }

    @Test func anAccountSettingsItemOpensThatAccount() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.act(on: item("x", anna.id))
        #expect(app.isShowingSettings)
        #expect(app.settingsAccount == anna.id)
    }

    @Test func moduleItemsJoinSyncProblems() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let module = FakeAttention()
        module.reports = [item("module.thing", anna.id)]
        app.modules.attention = [module]
        await app.refresh()
        #expect(app.attention.contains { $0.id == "module.thing" && $0.account == anna.id })
        // The offline sync has no password for the account.
        #expect(app.attention.contains { $0.account == anna.id && $0.id != "module.thing" })
    }

    @Test func attentionForAllAccountsIsTheUnion() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bert = try box.addAccount("bert@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let module = FakeAttention()
        module.reports = [item("module.a", anna.id), item("module.b", bert.id)]
        app.modules.attention = [module]
        await app.updateAttention()
        let all = Set(app.attention(for: nil).map(\.id))
        #expect(all.isSuperset(of: ["module.a", "module.b"]))
        #expect(app.attention(for: anna.id).allSatisfy { $0.account == anna.id })
        #expect(app.attention(for: anna.id).contains { $0.id == "module.a" })
        #expect(!app.attention(for: anna.id).contains { $0.id == "module.b" })
    }

    /// Mail shows the problems of the account whose folder is in view; Calendar and Contacts are of
    /// every account, so they show every account's.
    @Test func onlyMailNarrowsTheAttentionToTheAccountInView() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bert = try box.addAccount("bert@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let module = FakeAttention()
        module.reports = [item("module.a", anna.id), item("module.b", bert.id)]
        app.modules.attention = [module]
        await app.updateAttention()
        app.scope = .folder(try box.folder(anna, .inbox).id)
        app.selectedTab = .mail
        #expect(Set(app.attentionInView.map(\.account)) == [anna.id])
        for tab in [Tab.calendar, .contacts] {
            app.selectedTab = tab
            #expect(Set(app.attentionInView.map(\.account)) == [anna.id, bert.id])
        }
    }

    @Test func itemsOfARemovedAccountAreDropped() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let module = FakeAttention()
        let gone = AccountID(raw: UUID())
        module.reports = [item("module.a", anna.id), item("module.gone", gone)]
        app.modules.attention = [module]
        await app.updateAttention()
        #expect(app.attention.contains { $0.id == "module.a" })
        #expect(!app.attention.contains { $0.account == gone })
    }

    /// Contacts found outside the account's domain wait for a yes or no: the account says so everywhere.
    @Test func contactsOutsideTheDomainAskForAttention() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org", cardDAV: true)
        anna.cardDAVUnconfirmed = "https://dav.elsewhere.example/"
        try box.store.save(anna)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let asking = app.attention(for: anna.id).filter { $0.action == .accountSettings }
        #expect(asking.count == 1)
        try app.confirmCardDAV(anna.id)
        #expect(app.attention(for: anna.id).count == asking.count - 1)
    }

    /// A sign-in or password problem is put right in the password field.
    @Test func signInProblemsAskForThePassword() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        #expect(!app.asksForPassword(anna.id))
        // The offline sync has no password for the account.
        await app.refresh()
        #expect(app.asksForPassword(anna.id))
    }

    /// A look that started earlier and ends later never puts back what a later look has replaced.
    @Test func theLaterStartedLookWins() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let module = GatedAttention(account: anna.id)
        app.modules.attention = [module]
        let first = Task { await app.updateAttention() }
        await settle { module.calls == 1 }
        await app.updateAttention()
        module.release()
        await first.value
        #expect(app.attention.contains { $0.id == "new" })
        #expect(!app.attention.contains { $0.id == "old" })
    }

    /// A second tap on Sign in again while the first sign-in runs starts no other.
    @Test func aSecondSignInTapWhileOneRunsDoesNothing() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        let signIn = SlowSignIn()
        let provider = SlowProvider(made: signIn)
        anna.provider = provider.id
        anna.auth = .oauth
        try box.store.save(anna)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.modules.providers = [provider]
        let item = AttentionItem(AccountProblem(account: anna, problem: .signInAgain))
        app.act(on: item)
        await settle { signIn.started == 1 }
        #expect(app.isSigningIn(anna.id))
        app.act(on: item)
        await settle { signIn.started > 1 }
        #expect(signIn.started == 1)
        signIn.release()
        await settle { !app.isSigningIn(anna.id) }
        #expect(!app.isSigningIn(anna.id))
    }
}
