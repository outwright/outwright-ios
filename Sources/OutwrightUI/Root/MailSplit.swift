// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Mail on a wide screen, in the system's split view: on an iPad the sidebar with the folders, the
/// list, and the selected conversation; on a wide phone on its side the list and the conversation,
/// the folders staying in the drawer. The conversation can widen to the whole screen.
struct MailSplit: View {
    @Bindable var app: AppModel
    @Bindable var inbox: InboxModel
    let drawer: DrawerModel
    let calendar: CalendarModel
    let contacts: ContactsModel
    let layout: WideLayout
    @Binding var state: SidebarState
    @Binding var width: CGFloat
    @State private var listWidth: CGFloat = 0

    var body: some View {
        WideSplit(
            layout: layout, state: $state, width: $width,
            sidebar: {
                SidebarColumn(app: app, model: drawer, calendar: calendar, contacts: contacts, showsAccounts: false)
            },
            content: {
                Group {
                    if searches, let search = app.search {
                        SearchView(app: app, model: search)
                    } else {
                        InboxView(app: app, model: inbox, path: .constant([]), selects: true)
                    }
                }
                .standsOnTabCapsule()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { listWidth = $0 }
            },
            detail: {
                Group {
                    if searches { searchReading } else { reading }
                }
                .besideTabCapsule(from: state.isExpanded ? 0 : listWidth + 1)
            })
            .onChange(of: inbox.selected) { _, selected in if selected == nil { state.isExpanded = false } }
            .onChange(of: app.foldersChosen) { _, _ in state.folderChosen(width: width) }
    }

    /// Search in the list column (an iPad), its results opening beside it.
    private var searches: Bool { app.isSearching && app.searchInColumns }

    @ViewBuilder private var searchReading: some View {
        if let id = app.searchSelection {
            MessageView(
                app: app,
                model: ThreadModel(store: app.store, message: id, pending: app.pendingMail) { await app.fetchBody($0) },
                isListHidden: $state.isExpanded,
                onGone: { if app.searchSelection == id { app.searchSelection = nil } }, follows: id)
                .id(id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label { Text(ui: "No message selected") } icon: { Image(systemName: Icons.mail) }
        }
    }

    @ViewBuilder private var reading: some View {
        if let id = inbox.selected {
            MessageView(
                app: app,
                model: ThreadModel(store: app.store, message: id, pending: app.pendingMail) { await app.fetchBody($0) },
                isListHidden: $state.isExpanded,
                onGone: { if inbox.selected == id, !inbox.shows(id) { inbox.selected = nil } }, follows: id)
                .id(conversation(id))
        } else {
            placeholder
        }
    }

    /// What keeps the pane the same view: the conversation, so a reply joins it instead of replacing it.
    private func conversation(_ id: MessageID) -> AnyHashable {
        guard let row = inbox.sections.lazy.flatMap(\.rows).first(where: { $0.id == id }) else { return id }
        return [AnyHashable(row.accountID), AnyHashable(row.threadID)]
    }
}

/// The split view the wide tabs share: which columns show comes from `SidebarState`, the system's
/// own bars are hidden (each tab draws its header), and the avatar in a header shows or hides the
/// sidebar (`AppModel.toggleSidebar`).
struct WideSplit<Sidebar: View, Content: View, Detail: View>: View {
    let layout: WideLayout
    /// Mail's: the expand button gives the detail the width. Contacts' list stays.
    var expands = true
    @Binding var state: SidebarState
    @Binding var width: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: () -> Detail
    /// What the split view shows; follows `state`, and the owner's own changes go back into it.
    @State private var shown = NavigationSplitViewVisibility.doubleColumn

    /// The list's share of the width beside the reading pane, and the least it gets; with the sidebar
    /// beside it too, it takes a smaller share.
    static var listShare: CGFloat { 0.36 }
    static var listShareBesideSidebar: CGFloat { 0.3 }
    static var listMinimum: CGFloat { 300 }

    var body: some View {
        NavigationSplitView(columnVisibility: $shown) {
            sidebar()
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 400)
                .background(Theme.drawerBackground.ignoresSafeArea())
                .withoutSystemBars()
        } content: {
            content()
                .navigationSplitViewColumnWidth(
                    min: Self.listMinimum,
                    ideal: max(width * (shown == .all ? Self.listShareBesideSidebar : Self.listShare), Self.listMinimum)
                )
                .withoutSystemBars()
        } detail: {
            detail()
                .withoutSystemBars()
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: wanted, initial: true) { _, wanted in shown = wanted }
        .onChange(of: shown) { _, now in
            guard now != wanted else { return }
            // On a phone the split view has no sidebar to show; only the expand button changes it.
            if layout == .sidebar {
                state.apply(now, layout: layout, width: width, expands: expands)
            } else {
                shown = wanted
            }
        }
        .background(Theme.background)
    }

    /// The columns `state` asks for at this width.
    private var wanted: NavigationSplitViewVisibility { state.visibility(layout, width: width, expands: expands) }
}

/// A tab of two columns in the sidebar layout (the calendar): the sidebar and the tab beside it,
/// the sidebar shown by the same rules and choice as the other tabs'.
struct SidebarSplit<Sidebar: View, Detail: View>: View {
    let layout: WideLayout
    @Binding var state: SidebarState
    let width: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    @State private var shown = NavigationSplitViewVisibility.detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $shown) {
            sidebar()
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 400)
                .background(Theme.drawerBackground.ignoresSafeArea())
                .withoutSystemBars()
        } detail: {
            detail()
                .withoutSystemBars()
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: wanted, initial: true) { _, wanted in shown = wanted }
        .onChange(of: shown) { _, now in
            if now != wanted { state.applyTwoColumn(now, width: width) }
        }
    }

    private var wanted: NavigationSplitViewVisibility { state.twoColumnVisibility(layout, width: width) }
}

/// What a wide tab needs for its split view: the layout, the shared column state and the window's
/// width, and the drawer's model for the sidebar.
struct WideContext {
    var layout = WideLayout.column
    var state: Binding<SidebarState> = .constant(SidebarState())
    var width: Binding<CGFloat> = .constant(0)
    var drawer: DrawerModel?
}

extension View {
    /// The tab draws its own header, so the system's navigation bar (and its sidebar button) is hidden.
    /// The sidebar button is hidden with the bar, never removed: iPadOS keeps the sidebar on screen
    /// when its button is removed, whatever the visibility asks.
    fileprivate func withoutSystemBars() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// The window's layout: in `.sidebar` the avatar shows or hides the sidebar instead of opening the drawer.
    @Entry var wideLayout = WideLayout.column
}
