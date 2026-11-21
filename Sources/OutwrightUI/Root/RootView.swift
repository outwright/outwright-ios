// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI
import OutwrightModel

/// The app: tabs, the mail stack, and the drawer over everything.
public struct RootView: View {
    @Bindable var app: AppModel
    @State private var inbox: InboxModel
    @State private var drawer: DrawerModel
    @State private var calendar: CalendarModel
    @State private var contacts: ContactsModel
    @State private var path: [MessageID] = []
    /// Which columns of a wide tab show.
    @State private var sidebarState = SidebarState()
    /// The window's width, which decides whether the sidebar stands beside the list.
    @State private var splitWidth: CGFloat = 0
    /// The mail list is on screen (or coming back, as a swipe back begins): the tabs show with it.
    @State private var listInView = true
    /// The mail tab has just come back: the list appearing now does so under what is pushed, not as a swipe.
    @State private var mailTabReturning = false
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The compose request open, and whether it opened as a sheet.
    @State private var composeOnSheet: (id: ComposeRequest.ID, sheet: Bool)?

    public init(app: AppModel) {
        self.app = app
        _inbox = State(initialValue: InboxModel(
            store: app.store, scope: app.scope, refresher: { await app.pullRefresh() },
            olderFetcher: { scope in await app.sync.fetchOlder(scope, atLeast: 50) }, pending: app.pendingMail))
        _drawer = State(initialValue: DrawerModel(store: app.store, selected: nil, pending: app.pendingMail))
        _calendar = State(initialValue: CalendarModel(app: app))
        _contacts = State(initialValue: ContactsModel(app: app))
    }

    @Environment(\.verticalSizeClass) private var heightClass

    /// The layout the window's room gives.
    private var layout: WideLayout { WideLayout.of(width: widthClass, height: heightClass) }

    /// Wide enough for the list and the conversation side by side.
    private var isWide: Bool { layout.isWide }

    /// On a phone, a message or a contact's card pushed over its list has the screen, without the tabs.
    private var hidesTabs: Bool {
        guard !isWide else { return false }
        switch app.selectedTab {
        case .mail: return PushedList.covers(path: path, listInView: listInView)
        case .contacts: return PushedList.covers(path: contacts.path, listInView: contacts.isListInView)
        case .calendar: return false
        }
    }

    /// The compose request, for the sheet (`onSheet`) or for the full-screen cover.
    private func composeRequest(onSheet: Bool) -> Binding<ComposeRequest?> {
        Binding {
            guard let request = app.composeRequest else { return nil }
            let sheet = composeOnSheet.flatMap { $0.id == request.id ? $0.sheet : nil } ?? isWide
            return sheet == onSheet ? request : nil
        } set: { request in
            app.composeRequest = request
        }
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            TabBar(
                app: app, contacts: contacts, calendar: calendar,
                hidesTabs: hidesTabs,
                wide: WideContext(layout: layout, state: $sidebarState, width: $splitWidth, drawer: drawer)
            ) {
                if isWide {
                    MailSplit(
                        app: app, inbox: inbox, drawer: drawer, calendar: calendar, contacts: contacts,
                        layout: layout, state: $sidebarState, width: $splitWidth)
                } else {
                    NavigationStack(path: $path) {
                        InboxView(app: app, model: inbox, path: $path)
                            // The list appears as a swipe back begins and disappears again if it is
                            // given up, so the tabs come and go with the gesture, not after it.
                            .onAppear {
                                listInView = PushedList.inViewOnAppear(path: path, tabReturning: mailTabReturning)
                                mailTabReturning = false
                            }
                            .onDisappear { listInView = false }
                            .navigationDestination(for: MessageID.self) { id in
                                MessageView(
                                    app: app,
                                    model: ThreadModel(store: app.store, message: id, pending: app.pendingMail) {
                                        await app.fetchBody($0)
                                    })
                            }
                    }
                }
            }
            // Where the sidebar stands, it holds what the drawer would.
            if app.isDrawerOpen, layout != .sidebar {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { app.isDrawerOpen = false } }
                    .transition(.opacity)
                GeometryReader { geometry in
                    DrawerView(app: app, model: drawer, calendar: calendar, contacts: contacts)
                        // At the accessibility sizes the folders' names need nearly the whole width.
                        .frame(width: min(geometry.size.width * (dynamicTypeSize.isAccessibilitySize ? 0.92 : 0.84),
                            380))
                }
                .transition(.move(edge: .leading))
            }
        }
        .onAppear {
            app.appeared()
            #if os(iOS)
            // A message's body then shows at once, not after WebKit has started.
            ReadingRuleLists.warmUp()
            #endif
        }
        .task {
            // The watchers record their errors as they happen, and the modules see the accounts as they
            // are now: look every half minute, whichever tab is shown.
            while !Task.isCancelled {
                await app.updateAttention()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(
            Text(ui: "Not signed in"), isPresented: .constant(app.signInFailure != nil),
            presenting: app.signInFailure
        ) { _ in
            Button { app.signInFailure = nil } label: { Text(ui: "OK") }
        } message: { text in
            Text(text)
        }
        .onChange(of: app.isDrawerOpen, initial: true) { _, open in
            if open {
                app.reloadAccounts()
                drawer.selected = app.accountInView?.id ?? (app.accounts.count == 1 ? app.accounts.first?.id : nil)
                drawer.reload()
                if case .folder(let current) = app.scope {
                    drawer.reveal(current)
                }
            } else {
                app.drawerClosed()
            }
        }
        .onChange(of: app.scope) { _, _ in path = [] }
        // A message pushed: the tabs go as it slides in.
        .onChange(of: path) { _, now in if !now.isEmpty { listInView = false } }
        // Back on a tab its list may appear under what is pushed over it: the tabs follow what is pushed.
        // Whichever comes first, the list's appearing or this, the tabs stay off what is pushed; the
        // mark lasts until the list has appeared, or to the next turn when it does not.
        .onChange(of: app.selectedTab) { _, _ in
            listInView = path.isEmpty
            contacts.isListInView = contacts.path.isEmpty
            mailTabReturning = true
            contacts.isTabReturning = true
            Task { @MainActor in
                mailTabReturning = false
                contacts.isTabReturning = false
            }
        }
        .onChange(of: app.messageToOpen, initial: true) { _, message in
            guard let message else { return }
            app.messageToOpen = nil
            if isWide { inbox.selected = message } else { path = [message] }
        }
        // A turn between one column and two keeps the open conversation open.
        // Not at launch: the path and the selection are empty then, and a message opened at launch is kept.
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { splitWidth = $0 }
        .environment(\.wideLayout, layout)
        // The drawer is read as it opens; the iPad's sidebars stay on screen and follow the store.
        .task(id: layout == .sidebar) {
            if layout == .sidebar { await drawer.observe() }
        }
        .onChange(of: layout, initial: true) { _, now in app.searchInColumns = now == .sidebar }
        .onChange(of: layout) { _, now in
            sidebarState.layoutChanged()
            if now == .sidebar, app.isDrawerOpen { app.isDrawerOpen = false }
        }
        .onChange(of: app.sidebarToggles) { _, _ in
            withAnimation(.snappy) {
                sidebarState.toggle(layout, width: splitWidth, twoColumns: app.selectedTab == .calendar)
            }
        }
        .onChange(of: isWide) { _, wide in
            let carried = PaneSelection.carry(path: path, selected: inbox.selected, wide: wide)
            path = carried.path
            inbox.selected = carried.selected
        }
        // Screens' own sheets close through it when a tapped reminder needs the room (`closesForEvents`).
        .environment(app)
        .sheet(
            item: $app.eventToShow, onDismiss: { app.openPending() },
            content: { EventDetailsView(app: app, request: $0) })
        .sheet(
            item: $app.eventEditor, onDismiss: { app.openPending() },
            content: { EventEditorView(app: app, request: $0) })
        // Compose has the whole screen on a phone and is a sheet on a wide screen, chosen as it opens:
        // turning the phone while writing never swaps (and so closes) it.
        .sheet(item: composeRequest(onSheet: true), onDismiss: { app.openPending() },
            content: { ComposeSheet(app: app, request: $0) })
        .screenCover(item: composeRequest(onSheet: false), onDismiss: { app.openPending() },
            content: { ComposeSheet(app: app, request: $0) })
        .onChange(of: app.composeRequest?.id, initial: true) { _, id in
            composeOnSheet = id.map { ($0, isWide) }
        }
        .sheet(
            item: $app.personToShow, onDismiss: { app.openPending() },
            content: { PersonCardView(app: app, request: $0, presentation: .sheet) })
        .sheet(
            item: $app.contactEditor, onDismiss: { app.openPending() },
            content: { ContactEditorView(app: app, request: $0) })
        .screenCover(
            // The cover goes when search moves into the columns; that does not close search.
            isPresented: Binding { app.isSearching && !app.searchInColumns } set: { shown in
                if !app.searchInColumns { app.isSearching = shown }
            },
            onDismiss: { app.openPending() },
            content: {
                if let search = app.search { SearchView(app: app, model: search) }
            })
        .sheet(
            isPresented: Binding(
                get: { app.isAddingAccount && !app.addingFirstAccount }, set: { app.isAddingAccount = $0 }),
            onDismiss: { app.openPending() },
            content: { AddAccountSheet(app: app, placement: .sheet) })
        // The first account is added on a screen of its own that cannot be cancelled.
        .screenCover(
            isPresented: Binding(
                get: { app.isAddingAccount && app.addingFirstAccount }, set: { app.isAddingAccount = $0 }),
            onDismiss: { app.openPending() },
            content: { AddAccountSheet(app: app, placement: .firstRun) })
        .sheet(isPresented: $app.isShowingSettings) {
            app.openPending()
        } content: {
            SettingsView(app: app)
        }
        .sheet(
            isPresented: $app.isShowingHelp, onDismiss: { app.openPending() },
            content: {
                // Half height is a phone's way; an iPad's form sheet shows it whole.
                HelpView().presentationDetents(layout == .sidebar ? [.large] : [.medium, .large])
            })
        .sheet(
            item: $app.setupFileToOpen, onDismiss: { app.setupFileClosed() },
            content: { RestoreSetupView(app: app, url: $0.url) })
        .sheet(
            isPresented: $app.isBringingSetup, onDismiss: { app.openPending() },
            content: { NavigationStack { ReceiveSetupView(app: app, cancellable: true) } })
        // A setup file opened from AirDrop, Files or a mail.
        .onOpenURL { url in
            if url.isFileURL { app.openSetupFile(url) }
        }
    }
}

/// A short guide until there is a help site.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.swipeLeading) private var swipeRight = SwipeAction.leadingDefault.rawValue
    @AppStorage(SettingsKeys.swipeTrailing) private var swipeLeft = SwipeAction.trailingDefault.rawValue

    var body: some View {
        NavigationStack {
            List {
                swipeLine(SwipeAction(rawValue: swipeLeft) ?? .trailingDefault, edge: .trailing)
                swipeLine(SwipeAction(rawValue: swipeRight) ?? .leadingDefault, edge: .leading)
                ModuleLabel("Touch and hold a message to select several.", systemImage: Icons.rowSelected)
                ModuleLabel(
                    "Focused holds mail from people; Other holds newsletters and the like.", systemImage: Icons.focused)
                ModuleLabel("Pictures on the web are only downloaded when you ask.", systemImage: Icons.picture)
            }
            .navigationTitle(Text(ui: "Help"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }
}

extension HelpView {
    /// What a swipe does, as Settings chose it; nothing for None.
    @ViewBuilder func swipeLine(_ action: SwipeAction, edge: SwipeEdge) -> some View {
        if action != .none {
            let format = edge == .trailing
                ? L10n.string("Swipe left on a message to %@.") : L10n.string("Swipe right on a message to %@.")
            Label {
                Text(verbatim: String(format: format, action.helpPhrase))
            } icon: {
                Image(systemName: action.icon)
            }
        }
    }
}
