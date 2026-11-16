// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// A change the server did not take: what happened, and two ways on. Generic, so the calendar can
/// use it too.
struct ConflictBanner: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let primary: (title: LocalizedStringKey, action: () -> Void)
    let secondary: (title: LocalizedStringKey, action: () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.flag)
                Text(ui: title).font(.headline)
            }
            Text(ui: message).font(.subheadline).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 12) {
                Button(action: primary.action) { Text(ui: primary.title).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive, action: secondary.action) {
                    Text(ui: secondary.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
