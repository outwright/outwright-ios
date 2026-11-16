// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct AppModelTests {
    /// The first start, with no account: adding one is what comes up (#58).
    @Test func withNoAccountTheAppOpensAddAccount() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.appeared()
        #expect(app.isAddingAccount)
    }

    @Test func withAnAccountTheAppOpensNothing() throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.appeared()
        #expect(!app.isAddingAccount)
    }

    // Accounts that could not be read are not "no account" (review of #58).
    @Test func unreadableAccountsDoNotOpenAddAccount() throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        try box.store.breakAccountReads()
        app.appeared()
        #expect(!app.isAddingAccount)
    }

    @Test func draftsOpensTheDraftsOfTheAccountInView() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.openDrafts()
        #expect(app.scope == .folder(try box.folder(anna, .drafts).id))
        app.scope = .folder(try box.folder(bo, .inbox).id)
        app.openDrafts()
        #expect(app.scope == .folder(try box.folder(bo, .drafts).id))
    }

    @Test func closingDraftsReturnsToWhereTheOwnerWas() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        #expect(!app.isInDrafts)
        app.openDrafts()
        #expect(app.isInDrafts)
        app.closeDrafts()
        #expect(app.scope == .allAccounts, "back to every account's Inbox, where Drafts was opened from")
        let sent = try box.folder(anna, .sent)
        app.open(sent.id)
        app.openDrafts()
        app.closeDrafts()
        #expect(app.scope == .folder(sent.id))
    }

    @Test func closingDraftsOpenedFromTheDrawerGoesToTheAccountsInbox() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.open(try box.folder(anna, .drafts).id)
        #expect(app.isInDrafts)
        app.closeDrafts()
        #expect(app.scope == .folder(try box.folder(anna, .inbox).id))
    }

    @Test func choosingAFolderClosesTheDrawer() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.isDrawerOpen = true
        let sent = try box.folder(anna, .sent)
        app.open(sent.id)
        #expect(app.scope == .folder(sent.id))
        #expect(!app.isDrawerOpen)
        #expect(app.accountInView?.id == anna.id)
    }

    @Test func composeRequestsCarryTheirKind() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.compose(.reply(MessageID(raw: 4)))
        #expect(app.composeRequest?.kind == .reply(MessageID(raw: 4)))
    }

    @Test func syncFailuresAreShownByAccountAndKind() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        await app.refresh()
        #expect(app.syncProblems.map(\.account.id) == [anna.id])
        #expect(app.syncProblems.map(\.problem) == [.noPassword])
    }

    @Test func aTappedSyncProblemOpensItsAccountsSettings() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        await app.refresh()
        let problem = try #require(app.syncProblems.first)
        app.showSettings(for: problem)
        #expect(app.isShowingSettings)
        #expect(app.settingsAccount == anna.id)
        app.isShowingSettings = false
        app.showSettings()
        #expect(app.isShowingSettings)
        #expect(app.settingsAccount == nil)
    }

    @Test func aTappedProblemOfARemovedAccountOpensTheList() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        var gone = anna
        gone.id = AccountID()
        app.showSettings(for: AccountProblem(account: gone, problem: .unreachable))
        #expect(app.isShowingSettings)
        #expect(app.settingsAccount == nil)
    }

    @Test func syncErrorsAreSortedIntoKinds() {
        #expect(SyncProblem(.noPassword) == .noPassword)
        #expect(SyncProblem(.imap(.authenticationFailed)) == .signIn)
        #expect(SyncProblem(.imap(.startTLSNotOffered)) == .encryption)
        #expect(SyncProblem(.imap(.net(.io("x")))) == .unreachable)
        #expect(SyncProblem(.keychain(-1)) == .keychain)
        #expect(SyncProblem(.store("x")) == .storage)
        #expect(SyncProblem(.imap(.no("server text"))) == .server)
    }

    @Test func microsoftSyncErrorsAreSortedIntoKinds() {
        #expect(SyncProblem(.needsSignIn(AccountID())) == .signInAgain)
        #expect(SyncProblem(.oauth(.transport)) == .unreachable)
        #expect(SyncProblem(.oauth(.http(503))) == .server)
        #expect(SyncProblem(.noTokenSignIn) == .server)
        #expect(SyncProblem(.graph(.net)) == .unreachable)
        #expect(SyncProblem(.graph(.throttled)) == .server)
    }

    @Test func aMessageRefusedForGoodIsANotSentProblem() {
        #expect(SyncProblem(.smtp(.recipientRejected(code: 550, text: "x"))) == .notSent)
        #expect(SyncProblem(.smtp(.rejected(code: 552, text: "x"))) == .notSent)
        #expect(SyncProblem(.smtp(.invalidRecipient)) == .notSent)
        #expect(SyncProblem(.smtp(.smtpUTF8NotOffered)) == .notSent)
        #expect(SyncError.smtp(.smtpUTF8NotOffered).sendRefusal == .addressNeedsSMTPUTF8)
        #expect(SyncProblem(.smtp(.recipientRejected(code: 450, text: "x"))) == .server)
    }

    @Test func aComposeSheetThatGoesWithAnUnkeptDraftIsSaidWithoutHoldingWhatWaits() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.store.replaceFolders([try box.folder(anna, .inbox)], for: anna.id)
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Kept?"
        app.composeRequest = ComposeRequest(kind: .new)
        app.pendingPerson = PersonRequest(address: Address(name: nil, email: "bo@example.org"))
        app.composeRequest = nil
        // The sheet's dismiss and its disappearance come in either order.
        app.openPending()
        app.composeGone(model)
        #expect(app.draftNotKept == .noDraftsFolder)
        #expect(app.personToShow != nil, "a banner, not a sheet: what waited opens all the same")
        app.pendingCompose = ComposeRequest(kind: .new)
        app.openPending()
        #expect(app.composeRequest != nil, "and nothing waits behind it")
        #expect(app.draftNotKept == .noDraftsFolder, "the banner stays until the owner clears it")
    }

    @Test func aComposeSheetThatGoesAfterSendSaysNothing() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Gone"
        model.discard()
        app.composeGone(model)
        #expect(app.draftNotKept == nil)
    }

    @Test func composeAskedForWhileComposeIsOpenWaitsForIt() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.compose(.new)
        let first = app.composeRequest
        app.compose(.to(Address(name: nil, email: "bo@example.org")))
        #expect(app.composeRequest == first, "the open message is not swapped away")
        app.composeRequest = nil
        app.openPending()
        #expect(app.composeRequest?.kind == .to(Address(name: nil, email: "bo@example.org")))
    }
}
