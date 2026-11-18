// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import SwiftUI

/// The recipients and the subject in one line, while the text is written on a phone lying on its
/// side; a tap unfolds them.
struct FoldedFields: View {
    let recipients: [Address]
    let subject: String
    let unfold: () -> Void

    var body: some View {
        Button(action: unfold) {
            HStack(spacing: 6) {
                Text(verbatim: Self.names(recipients))
                    .foregroundStyle(.primary)
                Text(verbatim: subject).foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: Icons.unfolded).foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .font(.subheadline)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ui: "Recipients and subject"))
        .accessibilityIdentifier("compose.folded")
    }

    /// The recipients as the line shows them: each by name, or by address when it has none.
    static func names(_ recipients: [Address]) -> String {
        recipients.map { $0.name.flatMap { $0.isEmpty ? nil : $0 } ?? $0.email }.joined(separator: ", ")
    }
}
