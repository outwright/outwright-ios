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
    private func newApp() throws -> AppModel {
        let box = try Mailbox()
        return AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
    }

    @Test func aResultOpensBesideSearchInTheColumns() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.isSearching = true
        app.openSearchResult(MessageID(raw: 4))
        #expect(app.searchSelection == MessageID(raw: 4))
        #expect(app.isSearching)
        #expect(app.messageToOpen == nil)
    }

    @Test func aResultClosesTheCoverOnAPhone() throws {
        let app = try newApp()
        app.isSearching = true
        app.openSearchResult(MessageID(raw: 4))
        #expect(!app.isSearching)
        #expect(app.messageToOpen == MessageID(raw: 4))
    }

    @Test func searchMovesToTheCoverWhenTheWindowNarrows() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.searchText = "invoice"
        app.isSearching = true
        app.openSearchResult(MessageID(raw: 4))
        app.searchInColumns = false
        #expect(app.isSearching)
        #expect(app.searchText == "invoice")
        #expect(app.searchSelection == nil)
        #expect(app.messageToOpen == MessageID(raw: 4))
    }

    @Test func searchingFromAnotherTabOpensItInMail() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.selectedTab = .calendar
        app.startSearch()
        #expect(app.selectedTab == .mail)
        #expect(app.isSearching)
    }

    @Test func searchKeepsItsModelAcrossAResize() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.startSearch()
        let model = try #require(app.search)
        app.searchInColumns = false
        #expect(app.search === model)
    }

    @Test func closingSearchLetsItsModelGo() throws {
        let app = try newApp()
        app.startSearch()
        app.isSearching = false
        #expect(app.search == nil)
    }

    @Test func searchStartsWithTheLaunchQuery() throws {
        let app = try newApp()
        app.searchText = "invoice"
        app.isSearching = true
        #expect(app.search?.query == "invoice")
    }

    @Test func aFolderChosenDuringSearchInTheColumnsShowsTheFolder() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.startSearch()
        app.open(FolderID(raw: 3))
        #expect(!app.isSearching)
        #expect(app.scope == .folder(FolderID(raw: 3)))
    }

    @Test func aMessageOpenedFromElsewhereEndsSearchInTheColumns() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.startSearch()
        app.messageToOpen = MessageID(raw: 4)
        #expect(!app.isSearching)
        #expect(app.messageToOpen == MessageID(raw: 4))
    }

    @Test func choosingTheSameFolderAgainIsStillAChoice() throws {
        let app = try newApp()
        app.open(FolderID(raw: 3))
        let before = app.foldersChosen
        app.open(FolderID(raw: 3))
        #expect(app.foldersChosen != before)
    }

    @Test func anEventFromSearchInTheColumnsOpensOverIt() throws {
        let app = try newApp()
        app.searchInColumns = true
        app.isSearching = true
        let request = EventRequest(event: EventID(raw: 1), occurrence: nil)
        app.pendingEvent = request
        app.searchHandedOver()
        #expect(app.eventToShow == request)
        #expect(app.isSearching)
    }

    @Test func anEventFromTheSearchCoverWaitsForItToClose() throws {
        let app = try newApp()
        app.isSearching = true
        app.pendingEvent = EventRequest(event: EventID(raw: 1), occurrence: nil)
        app.searchHandedOver()
        #expect(!app.isSearching)
        #expect(app.eventToShow == nil)
    }

    /// The first start, with no account: adding one is what comes up (#58).
    @Test func withNoAccountTheAppOpensAddAccount() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.appeared()
        #expect(app.isAddingAccount)
    }

    /// Cancelling the first run's Add account would leave no way in, so it is told apart from the plus.
    @Test func theFirstAccountIsAddedFromAScreenThatCannotBeLeft() throws {
        var box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.appeared()
        #expect(app.addingFirstAccount)
        app.isAddingAccount = false
        _ = try box.addAccount("anna@example.org")
        app.reloadAccounts()
        app.isAddingAccount = true
        #expect(!app.addingFirstAccount)
    }

    /// The empty list says the mail is on its way until the account's first look at its Inbox has ended.
    @Test func anAccountIsInItsFirstSyncUntilItsInboxIsFetched() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        await app.updateFirstSync()
        #expect(app.isFirstSync(anna.id))
        await app.refresh()
        #expect(!app.isFirstSync(anna.id))
    }

    /// An account this build does not sync never gets its mail: its empty list is not on its way.
    @Test func anAccountThatIsNotSyncedIsNeverInItsFirstSync() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        var gone = try box.addAccount("gone@example.org")
        gone.provider = ProviderID(raw: "gone")
        try box.store.save(gone)
        let sync = offlineSync(store: box.store, secrets: InMemorySecretStore(), available: [.ownServer])
        let app = AppModel(store: box.store, sync: sync)
        await app.updateFirstSync()
        #expect(app.isFirstSync(anna.id))
        #expect(!app.isFirstSync(gone.id))
        await app.refresh()
        #expect(!app.isFirstSync(anna.id))
        #expect(!app.isFirstSync(gone.id))
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

    @Test func openingAFolderFromAnotherTabGoesToMail() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.selectedTab = .calendar
        app.open(try box.folder(anna, .inbox).id)
        #expect(app.selectedTab == .mail)
        app.selectedTab = .contacts
        app.openAllInboxes()
        #expect(app.selectedTab == .mail)
    }

    @Test func anEventFromAReminderClosesTheDrawer() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.isDrawerOpen = true
        app.showEvent(EventRequest(event: EventID(raw: 1), occurrence: nil))
        #expect(!app.isDrawerOpen)
    }

    /// The drawer and its sheet leave together, so the sheet's own dismissal may never be called.
    @Test func aDrawerSheetGoneWithTheDrawerStillLetsTheEventShow() throws {
        let box = try Mailbox()
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.isDrawerOpen = true
        app.localSheet(UUID(), isOpen: true, inDrawer: true)
        app.showEvent(EventRequest(event: EventID(raw: 1), occurrence: nil))
        #expect(app.eventToShow == nil)
        app.drawerClosed()
        #expect(app.eventToShow != nil)
    }

    @Test func gearOpensSettingsAtTheSelectedAccount() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.reloadAccounts()
        app.showSettings(account: anna.id)
        #expect(app.isShowingSettings && app.settingsAccount == anna.id)
        app.isShowingSettings = false
        app.showSettings(account: nil)
        #expect(app.isShowingSettings && app.settingsAccount == nil)
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
        let problem = try #require(app.attention.first)
        app.act(on: problem)
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
        app.act(on: AttentionItem(AccountProblem(account: gone, problem: .unreachable)))
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

    /// After Send a toast says the message is going, and goes once the send has been tried.
    @Test func theSendingToastGoesOnceTheSendIsTried() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.to = [Address(name: nil, email: "bo@example.org")]
        try model.send()
        let draft = try #require(model.draftID)
        await app.sent(draft)
        #expect(app.sending == nil)
    }

    /// A send the account refuses shows its banner as soon as the send was tried.
    @Test func aRefusedSendAsksForAttentionAtOnce() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.to = [Address(name: nil, email: "bo@example.org")]
        try model.send()
        let draft = try #require(model.draftID)
        // The offline sync has no password for the account.
        await app.sent(draft)
        #expect(app.asksForPassword(anna.id))
    }
}
