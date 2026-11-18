// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// All accounts, one badge each, and plus: in the drawer's column on a phone, in the tab rail on an iPad.
struct AccountBadges: View {
    @Bindable var app: AppModel
    @Bindable var model: DrawerModel
    let diameter: CGFloat

    var body: some View {
        if app.accounts.count > 1 {
            badge(selected: model.selected == nil) {
                Circle()
                    .fill(Theme.accent)
                    .overlay {
                        Image(systemName: Icons.allAccounts).font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                    }
            } action: {
                model.selected = nil
            }
            .accessibilityLabel(Text(ui: "All accounts"))
        }
        ForEach(model.accounts) { account in
            badge(selected: model.selected == account.id) {
                Avatar(
                    name: account.displayName, email: account.email, size: diameter,
                    colorIndex: account.colorIndex)
            } action: {
                model.selected = account.id
            }
            .accessibilityLabel(Text(account.email))
            .attentionDot(!app.attention(for: account.id).isEmpty, ring: Theme.drawerBackground)
        }
        Button {
            app.isAddingAccount = true
        } label: {
            Circle()
                .fill(Theme.background)
                .overlay(Circle().stroke(Theme.separator))
                .overlay(Image(systemName: Icons.add).font(.title2).foregroundStyle(.primary))
                .frame(width: diameter, height: diameter)
        }
        .accessibilityLabel(Text(ui: "Add account"))
    }

    private func badge(
        selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: diameter, height: diameter)
                .padding(3)
                .overlay(Circle().stroke(selected ? Theme.accent : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
    }
}
