// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI
import OutwrightModel

/// The app: tabs, the mail stack, and the drawer over everything.
public struct RootView: View {
    @Bindable var app: AppModel
    @State private var inbox: InboxModel
    @State private var drawer: DrawerModel
    @State private var path: [MessageID] = []
    @Environment(\.horizontalSizeClass) private var widthClass

    public init(app: AppModel) {
        self.app = app
        _inbox = State(initialValue: InboxModel(
            store: app.store, scope: app.scope, refresher: { await app.pullRefresh() },
            olderFetcher: { scope in await app.sync.fetchOlder(scope, atLeast: 50) }))
        _drawer = State(initialValue: DrawerModel(store: app.store, selected: nil))
    }

    /// Wide enough for the list and the conversation side by side.
    private var isWide: Bool { widthClass == .regular }

    public var body: some View {
        ZStack(alignment: .leading) {
            TabBar(app: app) {
                if isWide {
                    MailPanes(app: app, inbox: inbox)
                } else {
                    NavigationStack(path: $path) {
                        InboxView(app: app, model: inbox, path: $path)
                            .navigationDestination(for: MessageID.self) { id in
                                MessageView(
                                    app: app,
                                    model: ThreadModel(store: app.store, message: id) { await app.fetchBody($0) })
                            }
                    }
                }
            }
            if app.isDrawerOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { app.isDrawerOpen = false } }
                    .transition(.opacity)
                GeometryReader { geometry in
                    DrawerView(app: app, model: drawer)
                        .frame(width: min(geometry.size.width * 0.84, 380))
                }
                .transition(.move(edge: .leading))
            }
        }
        .onAppear { app.appeared() }
        .onChange(of: app.isDrawerOpen, initial: true) { _, open in
            if open {
                app.reloadAccounts()
                drawer.selected = app.accountInView?.id ?? (app.accounts.count == 1 ? app.accounts.first?.id : nil)
                drawer.reload()
                if case .folder(let current) = app.scope {
                    drawer.reveal(current)
                }
            }
        }
        .onChange(of: app.scope) { _, _ in path = [] }
        .onChange(of: app.messageToOpen, initial: true) { _, message in
            guard let message else { return }
            app.messageToOpen = nil
            if isWide { inbox.selected = message } else { path = [message] }
        }
        // A turn between one column and two keeps the open conversation open.
        // Not at launch: the path and the selection are empty then, and a message opened at launch is kept.
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
        .sheet(
            item: $app.composeRequest, onDismiss: { app.openPending() },
            content: { ComposeSheet(app: app, request: $0) })
        .sheet(
            item: $app.personToShow, onDismiss: { app.openPending() },
            content: { PersonCardView(app: app, request: $0) })
        .sheet(
            item: $app.contactEditor, onDismiss: { app.openPending() },
            content: { ContactEditorView(app: app, request: $0) })
        .searchCover(
            isPresented: $app.isSearching, onDismiss: { app.openPending() },
            content: { SearchView(app: app, query: app.searchText) })
        .sheet(
            isPresented: $app.isAddingAccount, onDismiss: { app.openPending() },
            content: { AddAccountView(app: app) })
        .sheet(isPresented: $app.isShowingSettings) {
            if app.addsAccountAfterSettings {
                app.addsAccountAfterSettings = false
                app.isAddingAccount = true
            } else if let report = app.diagnosticsAfterSettings {
                app.diagnosticsAfterSettings = nil
                app.compose(.diagnostics(report))
            } else {
                app.openPending()
            }
        } content: {
            SettingsView(app: app)
        }
        .sheet(
            isPresented: $app.isShowingHelp, onDismiss: { app.openPending() },
            content: { HelpView().presentationDetents([.medium, .large]) })
    }
}

/// A short guide until there is a help site.
struct HelpView: View {
    var body: some View {
        NavigationStack {
            List {
                ModuleLabel("Swipe left on a message to delete it.", systemImage: Icons.delete)
                ModuleLabel("Swipe right to flag it.", systemImage: "flag")
                ModuleLabel(
                    "Focused holds mail from people; Other holds newsletters and the like.", systemImage: "tray")
                ModuleLabel("Pictures on the web are only downloaded when you ask.", systemImage: "photo")
            }
            .navigationTitle(Text(ui: "Help"))
        }
    }
}
