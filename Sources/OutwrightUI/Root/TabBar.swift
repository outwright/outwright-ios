// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The three tabs. On iOS 26 the system draws the tab bar as floating glass; on a phone lying on its
/// side the tabs are a capsule of our own at the bottom left (`TabCapsule`); on an iPad (`.sidebar`)
/// they are a rail along the left edge (`TabRail`).
struct TabBar<Mail: View>: View {
    @Bindable var app: AppModel
    let contacts: ContactsModel
    let calendar: CalendarModel
    /// A message is pushed over the mail list on a phone: it has the screen, without the tabs.
    var hidesTabs = false
    var wide = WideContext()
    private var layout: WideLayout { wide.layout }
    @ViewBuilder let mail: () -> Mail

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var capsuleSize = CGSize.zero
    /// The safe area's left inset (the camera's side on its side): the capsule stands in it, the room
    /// it takes is counted from its edge, where the screens' own bars start.
    @State private var leadingInset: CGFloat = 0
    /// The undo toast's height and the gap over it; zero while none shows.
    @State private var toastRoom: CGFloat = 0

    /// On its side, the capsule stands in for the system tab bar (not while a message has the screen).
    private var showsCapsule: Bool { verticalSizeClass == .compact && !hidesTabs }

    /// The capsule's distance from the screen's left and bottom edges, and the gap beside it.
    private static var margin: CGFloat { 16 }
    private static var gap: CGFloat { 12 }

    /// The rail stands in for the system tab bar, which on an iPad would sit at the top with a sidebar
    /// of its own beside the folders'.
    private var showsRail: Bool { layout == .sidebar }

    var body: some View {
        HStack(spacing: 0) {
            if showsRail {
                TabRail(app: app, drawer: wide.drawer)
                Rectangle().fill(Theme.separator).frame(width: 1).ignoresSafeArea()
            }
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            SwiftUI.Tab(value: Tab.mail) {
                tabContent(mail())
            } label: {
                ModuleLabel("Mail", systemImage: Icons.mail)
            }
            SwiftUI.Tab(value: Tab.calendar) {
                tabContent(calendarTab)
            } label: {
                ModuleLabel("Calendar", systemImage: Icons.calendar)
            }
            SwiftUI.Tab(value: Tab.contacts) {
                tabContent(ContactsView(app: app, model: contacts, calendar: calendar, wide: wide))
            } label: {
                ModuleLabel("Contacts", systemImage: Icons.contacts)
            }
        }
        .tabStyle()
        .tint(Theme.accent)
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.leading) { leadingInset = $0 }
        .overlay(alignment: .bottomLeading) {
            if showsCapsule {
                TabCapsule(app: app)
                    .onGeometryChange(for: CGSize.self, of: \.size) { capsuleSize = $0 }
                    .padding(.leading, Self.margin)
                    .padding(.bottom, 4)
                    .ignoresSafeArea(.container, edges: .leading)
                    // Typing in a search field: the keyboard covers the capsule rather than lifting it.
                    .ignoresSafeArea(.keyboard)
            }
        }
    }

    /// On an iPad the calendars stand beside the calendar, as the folders beside the mail.
    @ViewBuilder private var calendarTab: some View {
        if layout == .sidebar, let drawer = wide.drawer {
            SidebarSplit(
                layout: layout, state: wide.state, width: wide.width.wrappedValue,
                sidebar: {
                    SidebarColumn(app: app, model: drawer, calendar: calendar, contacts: contacts, showsAccounts: false)
                },
                detail: { CalendarView(app: app, model: calendar) })
        } else {
            CalendarView(app: app, model: calendar)
        }
    }

    private var room: TabCapsuleRoom {
        guard showsCapsule else { return TabCapsuleRoom() }
        let width = Self.margin + capsuleSize.width + Self.gap - leadingInset
        return TabCapsuleRoom(width: max(width, 0), height: capsuleSize.height + 8)
    }

    private func tabContent(_ content: some View) -> some View {
        #if os(iOS)
        content
            .toolbar(verticalSizeClass == .compact || hidesTabs || showsRail ? .hidden : .automatic, for: .tabBar)
            .environment(\.tabCapsuleRoom, room)
            .environment(\.undoToastRoom, toastRoom)
            // Over every tab, above the tab bar (beside the capsule on its side): the last move or
            // delete shows wherever it was made.
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    SendingToast(sending: app.sending)
                    UndoToast(pending: app.pendingMail)
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { toastRoom = $0 > 0 ? $0 + 8 : 0 }
                .padding(.leading, room.width)
                .padding(.bottom, 8)
                .animation(.snappy, value: app.pendingMail.current?.id)
                .animation(.snappy, value: app.sending)
            }
        #else
        content
        #endif
    }
}

extension View {
    /// The phone's tab bar is the adaptable one; on an iPad that style adds a sidebar of the tabs
    /// beside the rail and the folders, so the iPad has the plain tab bar (hidden while the rail shows).
    /// The kind of device never changes, so the tab view keeps its state when the iPad turns.
    @ViewBuilder fileprivate func tabStyle() -> some View {
        #if canImport(UIKit)
            if UIDevice.current.userInterfaceIdiom == .pad {
                tabViewStyle(.tabBarOnly)
            } else {
                tabViewStyle(.sidebarAdaptable)
            }
        #else
            tabViewStyle(.sidebarAdaptable)
        #endif
    }
}
