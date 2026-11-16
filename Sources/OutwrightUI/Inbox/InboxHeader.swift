// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// The header: the avatar that opens the drawer, the folder's name, a glass capsule with
/// the bell and search; under it Focused / Other and Filter.
struct InboxHeader: View {
    @Bindable var app: AppModel
    @Bindable var inbox: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) { app.isDrawerOpen = true }
                } label: {
                    HeaderAvatar(app: app)
                }
                .accessibilityLabel(Text(ui: "Folders and accounts"))
                Text(app.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.headerText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("inbox.title")
                Spacer(minLength: 8)
                headerCapsule
            }
            HStack {
                if inbox.showsFocusedOther {
                    FocusedOtherPicker(selection: $inbox.inboxClass)
                }
                Spacer()
                FilterMenu(filter: $inbox.filter)
                    .accessibilityIdentifier("inbox.filter")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private var headerCapsule: some View {
        HStack(spacing: 22) {
            Button {
                app.isDoNotDisturb.toggle()
            } label: {
                Image(systemName: app.isDoNotDisturb ? "bell.slash" : Icons.bell)
            }
            .accessibilityLabel(Text(ui: "Do Not Disturb"))
            Button {
                app.isSearching = true
            } label: {
                Image(systemName: Icons.search)
            }
            .accessibilityLabel(Text(ui: "Search"))
        }
        .font(.title3)
        .foregroundStyle(Theme.headerText)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(Theme.accent.opacity(0.12)).interactive(), in: .capsule)
    }
}

/// The account in view, or every account's mark when all are shown.
struct HeaderAvatar: View {
    let app: AppModel

    var body: some View {
        if let account = app.accountInView ?? (app.accounts.count == 1 ? app.accounts.first : nil) {
            Avatar(name: account.displayName, email: account.email, size: 34, colorIndex: account.colorIndex)
                .overlay(Circle().stroke(Theme.header, lineWidth: 1.5))
        } else {
            Circle()
                .fill(Theme.headerTrack)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: Icons.allAccounts)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.headerText)
                }
        }
    }
}

/// Focused and Other as a capsule: the chosen side in the accent.
struct FocusedOtherPicker: View {
    @Binding var selection: InboxClass

    var body: some View {
        HStack(spacing: 0) {
            side(.focused, "Focused").accessibilityIdentifier("inbox.focused")
            side(.other, "Other").accessibilityIdentifier("inbox.other")
        }
        .padding(3)
        .background(Capsule().fill(Theme.headerTrack))
            }

    private func side(_ value: InboxClass, _ key: LocalizedStringKey) -> some View {
        Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(ui: key)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(selection == value ? Theme.onAccent : Theme.headerText)
                .background {
                    if selection == value {
                        Capsule().fill(Theme.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
