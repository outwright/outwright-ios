// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The tabs on a phone lying on its side: a glass capsule at the bottom left instead of the system
/// tab bar, so the screen's own bottom bars (a message's actions, New event) sit beside it rather
/// than on top of it, where the height is short.
struct TabCapsule: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 4) {
            item(.mail, "Mail", Icons.mail)
            item(.calendar, "Calendar", Icons.calendar)
            item(.contacts, "Contacts", Icons.contacts)
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func item(_ tab: Tab, _ name: LocalizedStringKey, _ icon: String) -> some View {
        let isSelected = app.selectedTab == tab
        return Button {
            app.selectedTab = tab
        } label: {
            ModuleLabel(name, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { if isSelected { Capsule().fill(Theme.headerTrack) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(tab)")
    }
}

/// The room the capsule takes from the bottom left corner of the screen; zero when it is not shown.
struct TabCapsuleRoom: Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
}

private struct TabCapsuleRoomKey: EnvironmentKey {
    static let defaultValue = TabCapsuleRoom()
}

extension EnvironmentValues {
    var tabCapsuleRoom: TabCapsuleRoom {
        get { self[TabCapsuleRoomKey.self] }
        set { self[TabCapsuleRoomKey.self] = newValue }
    }
}

extension View {
    /// A bar along the bottom moves right of the capsule.
    func clearOfTabCapsule() -> some View { modifier(ClearOfTabCapsule()) }

    /// A column of `width` at the screen's left: its bottom stands on the capsule. What is right of
    /// the column is told how much of the capsule still reaches past it.
    func standsOnTabCapsule() -> some View { modifier(StandsOnTabCapsule()) }

    /// A view that starts `offset` from the screen's left edge: it gets what of the capsule reaches it.
    func besideTabCapsule(from offset: CGFloat) -> some View { modifier(BesideTabCapsule(offset: offset)) }
}

private struct ClearOfTabCapsule: ViewModifier {
    @Environment(\.tabCapsuleRoom) private var room

    func body(content: Content) -> some View {
        content.padding(.leading, room.width)
    }
}

private struct StandsOnTabCapsule: ViewModifier {
    @Environment(\.tabCapsuleRoom) private var room

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: room.height) }
            .environment(\.tabCapsuleRoom, TabCapsuleRoom())
    }
}

private struct BesideTabCapsule: ViewModifier {
    @Environment(\.tabCapsuleRoom) private var room
    let offset: CGFloat

    func body(content: Content) -> some View {
        content.environment(
            \.tabCapsuleRoom,
            room.width > offset ? TabCapsuleRoom(width: room.width - offset, height: room.height) : TabCapsuleRoom())
    }
}
