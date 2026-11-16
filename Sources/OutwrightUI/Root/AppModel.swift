// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightMIME
public import OutwrightModel
public import OutwrightStore
public import OutwrightSync

public enum Tab: Hashable, Sendable {
    case mail, calendar, contacts
}

/// A request to open the compose sheet.
public struct ComposeRequest: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case new
        case reply(MessageID)
        case replyAll(MessageID)
        case forward(MessageID)
        case draft(MessageID)
        /// A new message to one address (from a person card).
        case to(Address)
        /// A new message with a diagnostics report attached (Settings' Send diagnostics).
        case diagnostics(Data)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// What the whole app shares: the store, sync, the tab, the mail scope, the drawer and compose.
@Observable @MainActor
public final class AppModel {
    public let store: MailStore
    public let sync: SyncCoordinator
    public var selectedTab: Tab = .mail
    public var scope: InboxScope = .allAccounts
    public var isDrawerOpen = false
    public var composeRequest: ComposeRequest?
    /// A compose sheet went away without ✕ or send and its draft could not be kept: a banner over
    /// the mail says so until the owner taps it away. Not a sheet or an alert, so it never contends
    /// with what opens next.
    public var draftNotKept: ComposeError?
    /// The person card to show: from the Contacts tab, or a sender or address in a message.
    public var personToShow: PersonRequest?
    /// Something to open once the sheet in front of it has gone (a second sheet can't be presented
    /// during a dismissal); the sheet's `onDismiss` calls `openPending()`.
    public var pendingCompose: ComposeRequest?
    public var pendingPerson: PersonRequest?
    /// The event whose details to show: from the calendar, or a tapped reminder.
    public var eventToShow: EventRequest?
    /// An event waiting for the sheet in front of it to close.
    public var pendingEvent: EventRequest?
    /// Asks the open screen-level sheets to close (each one counts), so a tapped reminder's event can
    /// show.
    public private(set) var localSheetCloses = 0
    @ObservationIgnored private var openLocalSheets: Set<UUID> = []
    /// Counts midnights and time-zone changes, which the calendar lays its days out again for.
    public private(set) var clockChanges = 0
    /// The app's clock, which the calendar reads now and today from (a test may move it).
    @ObservationIgnored public var now: () -> Date = Date.init
    /// The view the Calendar tab opens in (a launch argument may choose another).
    @ObservationIgnored public var initialCalendarMode: CalendarMode = .threeDay
    /// Whether this launch has asked for the reminders' permission already.
    @ObservationIgnored var remindersAsked = false
    /// The contact editor to show, and the one waiting for the person card to close.
    var contactEditor: ContactEditorRequest?
    var pendingContactEditor: ContactEditorRequest?
    /// The event editor to show, and the one waiting for the event's details to close.
    var eventEditor: EventEditorRequest?
    var pendingEventEditor: EventEditorRequest?
    /// The plus in the drawer; Task 8's add-account flow presents it.
    public var isAddingAccount = false
    public var isShowingSettings = false
    /// The account whose settings open over the list when settings opens; nil opens the list.
    public internal(set) var settingsAccount: AccountID?
    /// Settings' Add account: the add-account sheet opens once settings has gone.
    public var addsAccountAfterSettings = false
    /// Settings' Send diagnostics: the report built while settings showed it being prepared; it
    /// opens in compose once settings has gone.
    public var diagnosticsAfterSettings: Data?
    public var isShowingHelp = false
    /// The search button in the header; Task 8's search presents it.
    public var isSearching = false
    /// What search starts with when it opens (a launch argument); empty otherwise.
    public var searchText = ""
    /// The bell in the header. There are no notifications or sounds yet, so it changes nothing else.
    public var isDoNotDisturb = false
    public private(set) var accounts: [Account] = []
    /// Accounts whose last synchronisation failed, and why.
    public private(set) var syncProblems: [AccountProblem] = []
    /// A message to show on top of the list (from outside the list, such as a launch argument).
    public var messageToOpen: MessageID?
    /// What this build is made of beyond the open core (its composition).
    @ObservationIgnored public var modules = Modules()
    /// Where a diagnostics report reads its MetricKit payloads and log lines; empty in the sample.
    @ObservationIgnored public var diagnostics = DiagnosticsSource.empty
    /// New-mail notifications; nil where push cannot work (no app group, or the sample).
    @ObservationIgnored public var push: PushSupport?
    /// The last change of an account handed to push, for whoever must wait for it.
    @ObservationIgnored var pushRefresh: Task<Void, Never>?
    /// The last change of scene phase, which the next one waits for.
    @ObservationIgnored private var phaseChange: Task<Void, Never>?
    /// The Wi-Fi check the last return to the front brought, asked again for an account added since.
    @ObservationIgnored private var onWiFi: @Sendable () async -> Bool = { false }
    /// The whole refresh a pull starts behind it; one at a time.
    @ObservationIgnored private var fullRefresh: Task<Void, Never>?

    /// The words of the mails about meetings, in the app's language, for `SyncCoordinator`.
    public static var meetingWording: MeetingWording {
        MeetingWording(
            accepted: L10n.string("Accepted:"), tentative: L10n.string("Tentative:"),
            declined: L10n.string("Declined:"), line: L10n.string("%@ has replied to the invitation."),
            invited: L10n.string("%@ has invited you to this meeting."), cancelled: L10n.string("Cancelled:"),
            cancelledLine: L10n.string("%@ has cancelled this meeting."))
    }

    public init(store: MailStore, sync: SyncCoordinator) {
        self.store = store
        self.sync = sync
        reloadAccounts()
    }

    public func reloadAccounts() {
        accounts = (try? store.accounts()) ?? []
    }

    /// The app is on screen: with no account yet, adding one is the first thing it shows (#58).
    /// Accounts that could not be read are not taken for none.
    public func appeared() {
        reloadAccounts()
        if let stored = try? store.accounts(), stored.isEmpty { isAddingAccount = true }
    }

    /// The folder in view, when it is one folder.
    public var folderInView: Folder? {
        guard case .folder(let id) = scope else { return nil }
        return store.findFolder(id)
    }

    /// The account whose folder is in view; nil for every account's Inbox.
    public var accountInView: Account? {
        guard let folder = folderInView else { return nil }
        return accounts.first { $0.id == folder.accountID }
    }

    public var title: String {
        guard let folder = folderInView else { return L10n.string("Inbox") }
        return FolderNames.name(folder)
    }

    public func open(_ folder: FolderID) {
        scope = .folder(folder)
        scopeBeforeDrafts = nil
        isDrawerOpen = false
    }

    public func openAllInboxes() {
        scope = .allAccounts
        scopeBeforeDrafts = nil
        isDrawerOpen = false
    }

    /// Where Drafts was opened from with the Drafts button, to go back to when it is closed.
    @ObservationIgnored private var scopeBeforeDrafts: InboxScope?

    /// The Drafts of the account in view, or of the first account.
    public func openDrafts() {
        guard let account = accountInView ?? accounts.first,
            let drafts = (try? store.folders(account.id))?.first(where: { $0.kind == .drafts })
        else { return }
        let previous = isInDrafts ? scopeBeforeDrafts : scope
        open(drafts.id)
        scopeBeforeDrafts = previous
    }

    /// A Drafts folder is in view: the list offers a way back instead of Drafts and New mail.
    public var isInDrafts: Bool {
        folderInView?.kind == .drafts
    }

    /// Back from Drafts to where the Drafts button was pressed, else to that account's Inbox.
    public func closeDrafts() {
        if let previous = scopeBeforeDrafts {
            scope = previous
        } else if let account = accountInView,
            let inbox = (try? store.folders(account.id))?.first(where: { $0.kind == .inbox }) {
            scope = .folder(inbox.id)
        } else {
            scope = .allAccounts
        }
        scopeBeforeDrafts = nil
    }

    /// Opens the editor for a new contact.
    public func showNewContact() {
        contactEditor = ContactEditorRequest()
    }

    /// Opens the editor for a new event on the day (today when none).
    public func showNewEvent(day: Date? = nil) {
        eventEditor = EventEditorRequest(day: day)
    }

    /// Opens the editor for the event shown, once its details have closed.
    func edit(_ request: EventRequest, scope: EditScope) {
        pendingEventEditor = EventEditorRequest(editing: request, scope: scope)
        eventToShow = nil
    }

    /// Opens what waited for a sheet to close.
    public func openPending() {
        if let request = pendingCompose {
            pendingCompose = nil
            composeRequest = request
        }
        if let request = pendingPerson {
            pendingPerson = nil
            personToShow = request
        }
        if let request = pendingContactEditor {
            pendingContactEditor = nil
            contactEditor = request
        }
        if let request = pendingEventEditor {
            pendingEventEditor = nil
            eventEditor = request
        }
        if let request = pendingEvent, !isPresenting {
            pendingEvent = nil
            eventToShow = request
        }
    }

    /// The compose sheet went without ✕ or send, so it can't ask: its draft is kept, or the inbox's
    /// banner says it could not be.
    func composeGone(_ model: ComposeModel) {
        do throws(ComposeError) {
            try model.close()
        } catch {
            draftNotKept = error
        }
    }

    /// A message open in compose is never swapped away: another waits until it is closed.
    public func compose(_ kind: ComposeRequest.Kind) {
        let request = ComposeRequest(kind: kind)
        if composeRequest != nil {
            pendingCompose = request
        } else {
            composeRequest = request
        }
    }

    public func refresh() async {
        await sync.refreshAll()
        reloadAccounts()
        await updateSyncProblems()
    }

    /// A pull on the list: what it shows is brought in before the pull ends, and the rest
    /// (other folders, contacts, calendars) follows behind it unless it is already under way.
    public func pullRefresh() async {
        await sync.refreshShown(scope)
        await updateSyncProblems()
        guard fullRefresh == nil else { return }
        fullRefresh = Task {
            await refresh()
            fullRefresh = nil
        }
    }

    /// Reads the coordinator's last errors (the watchers record theirs as they go).
    public func updateSyncProblems() async {
        let errors = await sync.lastErrors
        syncProblems = accounts.compactMap { account in
            errors[account.id].map { AccountProblem(account: account, problem: SyncProblem($0)) }
        }
    }

    /// An account was just added: its mail is read now, and its Inbox watched from now on, its bodies
    /// prefetched as on a return to the front (so an invitation in it reaches the calendar now).
    public func accountAdded() async {
        reloadAccounts()
        await refresh()
        await sceneChanged(toActive: true, onWiFi: onWiFi).value
    }

    /// The app came to the front (its Inboxes are watched, bodies prefetched on Wi-Fi) or went to
    /// the background (the watching stops). Each change waits for the one before it, so a quick
    /// trip to the background can't stop the watchers the return to the front started.
    @discardableResult
    public func sceneChanged(toActive active: Bool, onWiFi: @escaping @Sendable () async -> Bool = { false })
        -> Task<Void, Never> {
        if !active {
            // What is in the store now was there to be seen: it is never announced. At once, before
            // the app can be suspended.
            try? store.moveNewMailMarks(now: now())
        }
        let sync = sync
        let previous = phaseChange
        let change = Task {
            await previous?.value
            if active {
                await sync.startForeground()
            } else {
                await sync.stopForeground()
            }
        }
        phaseChange = change
        if active {
            self.onWiFi = onWiFi
            Task {
                await change.value
                await sync.prefetchInboxBodies(onWiFi: await onWiFi())
            }
        }
        return change
    }

    /// The phone moved to another network: the watching starts again on new connections, after
    /// any change of phase under way (in the background it does nothing).
    @discardableResult
    public func networkChanged() -> Task<Void, Never> {
        let sync = sync
        let previous = phaseChange
        let change = Task {
            await previous?.value
            await sync.networkChanged()
        }
        phaseChange = change
        return change
    }

    /// A reminder was tapped: its event's details open over the Calendar tab. A sheet with nothing
    /// unsaved in it (a person card, help, a screen's filter or picker) closes first; over compose, the
    /// contact editor, the event editor, search, settings or add account (work under way) the event
    /// waits until that sheet is closed.
    public func showEvent(_ request: EventRequest) {
        selectedTab = .calendar
        if holdsWork {
            pendingEvent = request
        } else if personToShow != nil || isShowingHelp || !openLocalSheets.isEmpty {
            pendingEvent = request
            personToShow = nil
            isShowingHelp = false
            if !openLocalSheets.isEmpty { localSheetCloses &+= 1 }
        } else {
            eventToShow = request
        }
    }

    /// A sheet where the owner may have work under way is in front.
    private var holdsWork: Bool {
        composeRequest != nil || contactEditor != nil || eventEditor != nil || isSearching || isShowingSettings
            || isAddingAccount
    }

    /// A sheet other than an event's details is in front.
    private var isPresenting: Bool {
        holdsWork || personToShow != nil || isShowingHelp || !openLocalSheets.isEmpty
    }

    /// A sheet a screen shows over itself, with nothing unsaved in it (a filter, a picker, an
    /// attachment), opened or closed: see `closesForEvents`.
    func localSheet(_ id: UUID, isOpen: Bool) {
        if isOpen { openLocalSheets.insert(id) } else { openLocalSheets.remove(id) }
    }

    /// The phone moved to another time zone: the events are laid out again for it.
    public func phoneZoneChanged() async {
        await sync.phoneZoneChanged()
        clockChanges &+= 1
    }

    /// Midnight passed: the events are laid out for the new day's window.
    public func dayChanged() async {
        await sync.dayChanged()
        clockChanges &+= 1
    }

    public func fetchBody(_ message: MessageID) async {
        try? await sync.fetchBody(message)
    }
}
