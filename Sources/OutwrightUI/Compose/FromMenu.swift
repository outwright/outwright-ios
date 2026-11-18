// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The middle of compose's header: what is written and the account it is sent from. With more than
/// one account it is a menu of them (avatar, name and address) under a chevron.
struct FromMenu: View {
    @Bindable var model: ComposeModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if model.accounts.count < 2 {
            accountLabel
        } else {
            Menu {
                Picker(selection: $model.from) {
                    ForEach(model.accounts) { account in
                        Label {
                            Text(account.displayName.isEmpty ? account.email : account.displayName)
                            if !account.displayName.isEmpty { Text(account.email) }
                        } icon: {
                            avatarImage(account)
                        }
                        .tag(account.id)
                    }
                } label: {
                    Text(ui: "From")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    accountLabel
                    Image(systemName: Icons.unfolded)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        // A hint, not text: it stays small so the account keeps the room at large sizes.
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "From"))
        }
    }

    /// An account's avatar as a picture: a menu shows pictures, not views.
    private func avatarImage(_ account: Account) -> Image {
        let renderer = ImageRenderer(
            content: Avatar(name: account.displayName, email: account.email, size: 28, colorIndex: account.colorIndex))
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return Image(systemName: Icons.person) }
        return Image(decorative: image, scale: displayScale).renderingMode(.original)
    }

    /// At the accessibility sizes the title and address have a row of their own and wrap to a second line.
    private var lines: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    private var accountLabel: some View {
        HStack(spacing: 12) {
            if let account = model.account {
                Avatar(name: account.displayName, email: account.email, size: 36, colorIndex: account.colorIndex)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(lines)
                Text(model.account?.email ?? "")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(lines)
                    .truncationMode(.middle)
            }
            // A menu's label is laid out on one line unless told it may grow.
            .fixedSize(horizontal: false, vertical: lines > 1)
        }
    }

    private var title: LocalizedStringKey {
        switch model.purpose {
        case .new: "New message"
        case .reply: "Reply (title)"
        case .forward: "Forward (title)"
        }
    }
}
