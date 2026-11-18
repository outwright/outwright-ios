// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The glass capsule at the bottom right of the list: Drafts and New mail; in Drafts, a close
/// button that goes back.
struct FloatingActions: View {
    let app: AppModel

    var body: some View {
        if app.isInDrafts {
            Button {
                app.closeDrafts()
            } label: {
                Image(systemName: Icons.close)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .padding(18)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text(ui: "Close Drafts"))
            .accessibilityIdentifier("drafts.close")
        } else {
            capsule
        }
    }

    private var capsule: some View {
        HStack(spacing: 26) {
            Button {
                app.openDrafts()
            } label: {
                Image(systemName: Icons.drafts)
            }
            .accessibilityLabel(Text(ui: "Drafts"))
            Button {
                app.compose(.new)
            } label: {
                Image(systemName: Icons.compose)
            }
            .accessibilityLabel(Text(ui: "New mail"))
        }
        .font(.title2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
