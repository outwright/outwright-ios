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
        /// A new message to an event's people, about it (Email attendees).
        case people([Address], subject: String)
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
    /// The last move or delete, waiting out its undo window.
    public let pendingMail: PendingMail
    /// Synced accounts whose Inbox the sync coordinator has not looked at yet; see `isFirstSync`.
    public internal(set) var awaitingFirstInbox: Set<AccountID> = []
    public var selectedTab: Tab = .mail
    public var scope: InboxScope = .allAccounts
    public var isDrawerOpen = false
    /// Counts the avatar's showing or hiding the iPad's sidebar (`toggleSidebar`), and the folders chosen.
    public internal(set) var sidebarToggles = 0
    public internal(set) var foldersChosen = 0
    public var composeRequest: ComposeRequest?
    /// A compose sheet went away without ✕ or send and its draft could not be kept: a banner over
    /// the mail says so until the owner taps it away. Not a sheet or an alert, so it never contends
    /// with what opens next.
    public var draftNotKept: ComposeError?
    /// A message just sent, while the toast says it is being sent. A refusal shows as the account's
    /// attention (`SyncProblem.notSent`, leading to Drafts), from this sync or any later one.
    public internal(set) var sending: SendingMail?
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
    /// The local sheets that stand in the drawer, which go when it does.
    @ObservationIgnored private var drawerLocalSheets: Set<UUID> = []
    /// Counts midnights and time-zone changes, which the calendar lays its days out again for.
    public internal(set) var clockChanges = 0
    /// The app's clock, which the calendar reads now and today from (a test may move it).
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Keeps the app icon's number up to date (`showBadge`).
    @ObservationIgnored var badgeWatch: Task<Void, Never>?
    /// The view the Calendar tab opens in when a launch argument chooses one; otherwise the calendar
    /// opens in the view last chosen (`SettingsKeys.calendarMode`).
    @ObservationIgnored public var initialCalendarMode: CalendarMode?
    /// The contact editor to show; what a card sheet asked for, to open once it has gone (`afterCard`).
    var contactEditor: ContactEditorRequest?
    @ObservationIgnored var afterCardClosed: (() -> Void)?
    /// The event editor to show, and the one waiting for the event's details to close.
    var eventEditor: EventEditorRequest?
    var pendingEventEditor: EventEditorRequest?
    /// Add account is open (Settings pushes its own page instead).
    public var isAddingAccount = false {
        didSet { if isAddingAccount, !oldValue { addingFirstAccount = accounts.isEmpty } }
    }
    /// Add account opened with no account yet: a screen that cannot be left until one is added.
    public private(set) var addingFirstAccount = false
    public var isShowingSettings = false
    /// The account whose settings open over the list when settings opens; nil opens the list.
    public internal(set) var settingsAccount: AccountID?
    /// Settings' Send diagnostics: the report built while settings showed it being prepared; it
    /// opens in compose once settings has gone.
    public var diagnosticsAfterSettings: Data?
    public var isShowingHelp = false
    /// A setup file opened from elsewhere: the one shown, and the one waiting for a sheet to close.
    var setupFileToOpen: SetupFileRequest?
    var pendingSetupFile: SetupFileRequest?
    /// The search button in the header opens search.
    public var isSearching = false { didSet { searchChanged() } }
    /// The open search, kept while the window moves it between the cover and the columns.
    public internal(set) var search: SearchModel?
    /// What search starts with when it opens (a launch argument, the query before a resize), else empty.
    public var searchText = ""
    /// Search stands in the list column, results beside it (an iPad), instead of covering the screen.
    public var searchInColumns = false {
        didSet { searchColumnsChanged(from: oldValue) }
    }
    /// The search result open in the reading pane beside search in the columns.
    public var searchSelection: MessageID?
    /// Do Not Disturb as the bell shows it; the value itself is kept in the app group's defaults.
    public internal(set) var doNotDisturbValue = DoNotDisturb()
    @ObservationIgnored var doNotDisturbEnd: Task<Void, Never>?
    /// The reminders planned again after the bell changed.
    @ObservationIgnored var doNotDisturbReplan: Task<Void, Never>?
    public private(set) var accounts: [Account] = []
    /// Accounts whose last synchronisation failed, and why.
    public internal(set) var syncProblems: [AccountProblem] = []
    /// What the last look found wrong with the accounts (sync problems, then the modules' items);
    /// `attention` adds what the accounts themselves say.
    var reportedAttention: [AttentionItem] = []
    /// Sign in again from a banner failed: what to tell the owner.
    public var signInFailure: String?
    /// The accounts whose sign-in a banner started and that is still under way.
    var signingIn: Set<AccountID> = []
    /// Counts looks for attention, so a look that ends after a later one began is dropped.
    @ObservationIgnored var attentionLooks = 0
    /// A message to show on top of the list (from outside the list, such as a launch argument).
    public var messageToOpen: MessageID? { didSet { if messageToOpen != nil { messageOpening() } } }
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
    /// What the last return to the front does once the watching has started: the Inbox bodies
    /// prefetch and the look at what needs attention.
    @ObservationIgnored var frontFollowUps: Task<Void, Never>?
    /// The Wi-Fi check the last return to the front brought, asked again for an account added since.
    @ObservationIgnored var onWiFi: @Sendable () async -> Bool = { false }
    /// Where Drafts was opened from with the Drafts button, to go back to when it is closed.
    @ObservationIgnored var scopeBeforeDrafts: InboxScope?
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
        pendingMail = PendingMail(store: store)
        reloadAccounts()
        reloadDoNotDisturb()
    }

    public func reloadAccounts() {
        accounts = (try? store.accounts()) ?? []
    }

    /// The app is on screen: with no account yet, adding one is the first thing it shows (#58).
    /// Accounts that could not be read are not taken for none. A setup file opened at launch goes first.
    public func appeared() {
        reloadAccounts()
        guard setupFileToOpen == nil, pendingSetupFile == nil else { return }
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

    /// Opens the editor for a new contact.
    public func showNewContact() {
        contactEditor = ContactEditorRequest()
    }

    /// Opens the editor for a new event on the day (today when none), or at the time tapped.
    public func showNewEvent(day: Date? = nil, start: Date? = nil) {
        eventEditor = EventEditorRequest(day: day, start: start)
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
        if let open = afterCardClosed {
            afterCardClosed = nil
            open()
        }
        if let request = pendingEventEditor {
            pendingEventEditor = nil
            eventEditor = request
        }
        if let request = pendingEvent, !isPresenting {
            pendingEvent = nil
            eventToShow = request
        }
        if let request = pendingSetupFile, !isPresenting, eventToShow == nil {
            pendingSetupFile = nil
            setupFileToOpen = request
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
        await updateFirstSync()
        await updateAttention()
    }

    /// A pull on the list: what it shows is brought in before the pull ends, and the rest
    /// (other folders, contacts, calendars) follows behind it unless it is already under way.
    public func pullRefresh() async {
        await sync.refreshShown(scope)
        await updateFirstSync()
        await updateAttention()
        guard fullRefresh == nil else { return }
        fullRefresh = Task {
            await refresh()
            fullRefresh = nil
        }
    }

    /// The app came to the front (its Inboxes are watched, bodies prefetched on Wi-Fi) or went to
    /// the background (the watching stops). Each change waits for the one before it, so a quick
    /// trip to the background can't stop the watchers the return to the front started.
    @discardableResult
    public func sceneChanged(toActive active: Bool, onWiFi: @escaping @Sendable () async -> Bool = { false })
        -> Task<Void, Never> {
        if !active {
            // What is in the store now was there to be seen: it is never announced. At once, before
            // the app can be suspended, as is the move or delete waiting out its undo window.
            pendingMail.commitNow()
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
            let prefetch = Task {
                await change.value
                await sync.prefetchInboxBodies(onWiFi: await onWiFi())
            }
            // What went wrong while away, and what the modules see now.
            let attention = Task {
                await change.value
                await updateAttention()
            }
            frontFollowUps = Task {
                await prefetch.value
                await attention.value
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
        isDrawerOpen = false
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
    var holdsWork: Bool {
        composeRequest != nil || contactEditor != nil || eventEditor != nil || (isSearching && !searchInColumns)
            || isShowingSettings || isAddingAccount || setupFileToOpen != nil
    }

    /// A sheet other than an event's details is in front.
    var isPresenting: Bool {
        holdsWork || personToShow != nil || isShowingHelp || !openLocalSheets.isEmpty
    }

    /// A sheet a screen shows over itself, with nothing unsaved in it (a filter, a picker, an
    /// attachment), opened or closed: see `closesForEvents`.
    func localSheet(_ id: UUID, isOpen: Bool, inDrawer: Bool = false) {
        if isOpen { openLocalSheets.insert(id) } else { openLocalSheets.remove(id) }
        if inDrawer {
            if isOpen { drawerLocalSheets.insert(id) } else { drawerLocalSheets.remove(id) }
        }
    }

    /// The drawer went. Its sheets went with it, and may never have said so: they are forgotten, and
    /// what waited for them is shown.
    func drawerClosed() {
        openLocalSheets.subtract(drawerLocalSheets)
        drawerLocalSheets = []
        openPending()
    }
}
