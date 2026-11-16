// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Under the subject: what the lock does to this message, said as it changes.
struct ProtectionNoteRow: View {
    let note: ProtectionNote

    var body: some View {
        Label {
            Text(ui: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityIdentifier("compose.protectionNote")
    }

    private var text: LocalizedStringKey {
        switch note {
        case .encrypted:
            "Encrypted and signed: only you and the recipients can read it, and they can see it's from you."
        case .checking: "Looking up the recipients' keys…"
        case .notEveryone: "Some recipients can't receive encrypted mail. You'll be asked before it's sent."
        case .notEncrypted: "Not encrypted: sent as ordinary email."
        case .signed: "Signed: anyone can read it, and it shows it's from you."
        case .cannotProtect: "This account can't encrypt yet. You'll be asked before it's sent."
        }
    }

    private var icon: String {
        switch note {
        case .encrypted: "lock.fill"
        case .notEveryone, .cannotProtect: "exclamationmark.triangle"
        case .notEncrypted: "lock.open"
        case .signed: "signature"
        case .checking: "magnifyingglass"
        }
    }

    private var color: Color {
        switch note {
        case .encrypted: .accentColor
        case .notEveryone, .cannotProtect: .orange
        case .notEncrypted, .checking, .signed: .secondary
        }
    }
}
