// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Under the subject: what protecting this message comes to, said as it changes. When Send will stop
/// because the account can't encrypt, it offers to set the account up.
struct ProtectionNoteRow: View {
    let note: ProtectionNote
    /// Opens where the account is set up to encrypt; nil when the build has nothing to set up.
    var setUp: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(ui: text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon)
            }
            .foregroundStyle(color)
            if note == .cannotProtect, let setUp {
                Button(action: setUp) {
                    Text(ui: "Set up encryption for this account")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("compose.setUpEncryption")
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.protectionNote")
    }

    private var text: LocalizedStringKey {
        switch note {
        case .encrypted:
            "Encrypted and signed: only you and the recipients can read it, and they can see it's from you."
        case .keyChanged: "Encrypted, but a recipient's key has changed. Tap their name to look at it."
        case .checking: "Looking up the recipients' keys…"
        case .notEveryone: "Some recipients can't receive encrypted mail. You'll be asked before it's sent."
        case .cannotProtect: "This account can't encrypt yet. You'll be asked before it's sent."
        }
    }

    private var icon: String {
        switch note {
        case .encrypted: Icons.locked
        case .keyChanged, .notEveryone, .cannotProtect: Icons.warning
        case .checking: Icons.search
        }
    }

    private var color: Color {
        switch note {
        case .encrypted: Theme.accent
        case .keyChanged, .notEveryone, .cannotProtect: Theme.warning
        case .checking: Theme.secondaryText
        }
    }
}

/// Under the subject: what the protection itself has to say about the account, in its own words.
struct ProtectionNoticeRow: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Icons.warning)
        }
        .foregroundStyle(Theme.warning)
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityIdentifier("compose.protectionNotice")
    }
}
