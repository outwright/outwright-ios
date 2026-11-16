// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The three tabs. On iOS 26 the system draws the tab bar as floating glass; on a phone lying on its
/// side the tabs are a capsule of our own at the bottom left (`TabCapsule`).
struct TabBar<Mail: View>: View {
    @Bindable var app: AppModel
    @State private var contacts: ContactsModel
    @State private var calendar: CalendarModel
    @ViewBuilder let mail: () -> Mail

    init(app: AppModel, @ViewBuilder mail: @escaping () -> Mail) {
        self.app = app
        self.mail = mail
        _contacts = State(initialValue: ContactsModel(app: app))
        _calendar = State(initialValue: CalendarModel(app: app))
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var capsuleSize = CGSize.zero
    /// The safe area's left inset (the camera's side on its side): the capsule stands in it, the room
    /// it takes is counted from its edge, where the screens' own bars start.
    @State private var leadingInset: CGFloat = 0

    /// On its side, the capsule stands in for the system tab bar.
    private var showsCapsule: Bool { verticalSizeClass == .compact }

    /// The capsule's distance from the screen's left and bottom edges, and the gap beside it.
    private static var margin: CGFloat { 16 }
    private static var gap: CGFloat { 12 }

    var body: some View {
        TabView(selection: $app.selectedTab) {
            SwiftUI.Tab(value: Tab.mail) {
                tabContent(mail())
            } label: {
                ModuleLabel("Mail", systemImage: Icons.mail)
            }
            SwiftUI.Tab(value: Tab.calendar) {
                tabContent(CalendarView(app: app, model: calendar))
            } label: {
                ModuleLabel("Calendar", systemImage: Icons.calendar)
            }
            SwiftUI.Tab(value: Tab.contacts) {
                tabContent(ContactsView(app: app, model: contacts))
            } label: {
                ModuleLabel("Contacts", systemImage: Icons.contacts)
            }
        }
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

    private var room: TabCapsuleRoom {
        guard showsCapsule else { return TabCapsuleRoom() }
        let width = Self.margin + capsuleSize.width + Self.gap - leadingInset
        return TabCapsuleRoom(width: max(width, 0), height: capsuleSize.height + 8)
    }

    private func tabContent(_ content: some View) -> some View {
        #if os(iOS)
        content
            .toolbar(showsCapsule ? .hidden : .automatic, for: .tabBar)
            .environment(\.tabCapsuleRoom, room)
        #else
        content
        #endif
    }
}
