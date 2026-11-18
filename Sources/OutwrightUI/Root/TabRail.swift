// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The tabs on an iPad: a narrow column along the left edge, the three tabs at its top, the accounts
/// under them and help and settings at its foot, so they are there while the sidebar is hidden. The
/// account chosen here is the one the sidebar shows, as in the drawer on a phone.
struct TabRail: View {
    @Bindable var app: AppModel
    var drawer: DrawerModel?
    @ScaledMetric(relativeTo: .title2) private var itemSize: CGFloat = 48
    /// A badge with its ring is as wide as a tab.
    private var badgeDiameter: CGFloat { itemSize - 6 }

    var body: some View {
        VStack(spacing: 8) {
            item(.mail, "Mail", Icons.mail)
            item(.calendar, "Calendar", Icons.calendar)
            item(.contacts, "Contacts", Icons.contacts)
            if let drawer {
                Rectangle().fill(Theme.separator).frame(width: itemSize - 16, height: 1)
                    .padding(.vertical, 8)
                ScrollView {
                    VStack(spacing: 12) {
                        AccountBadges(app: app, model: drawer, diameter: badgeDiameter)
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Spacer()
            }
            Button {
                app.isShowingHelp = true
            } label: {
                Image(systemName: Icons.help).frame(width: itemSize, height: itemSize)
            }
            .accessibilityLabel(Text(ui: "Help"))
            Button {
                app.showSettings(account: app.accountInView?.id)
            } label: {
                Image(systemName: Icons.settings).frame(width: itemSize, height: itemSize)
            }
            .accessibilityLabel(Text(ui: "Settings"))
        }
        .font(.title2)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        // Icons only: past the largest standard size they would not fit the rail.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(Theme.drawerBackground.ignoresSafeArea())
    }

    private func item(_ tab: Tab, _ name: LocalizedStringKey, _ icon: String) -> some View {
        let isSelected = app.selectedTab == tab
        return Button {
            app.selectedTab = tab
        } label: {
            ModuleLabel(name, systemImage: icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(isSelected ? Theme.accent : Color.primary)
                .frame(width: itemSize, height: itemSize)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 12).fill(Theme.headerTrack) }
                }
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(tab)")
    }
}
