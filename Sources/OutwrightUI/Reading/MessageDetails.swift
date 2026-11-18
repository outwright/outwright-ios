// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// Show details: who, to whom, when.
struct MessageDetails: View {
    @Environment(\.dismiss) private var dismiss
    let row: MessageRow
    let content: MessageContent?
    let onPerson: (Address) -> Void

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent { people([row.from]) } label: { Text(ui: "From") }
                LabeledContent { people(content?.to ?? row.to) } label: { Text(ui: "To") }
                if !(content?.cc ?? row.cc).isEmpty {
                    LabeledContent { people(content?.cc ?? row.cc) } label: { Text(ui: "Cc") }
                }
                LabeledContent { Text(row.date.formatted(date: .complete, time: .shortened)) } label: {
                    Text(ui: "Date")
                }
                LabeledContent { Text(verbatim: row.subject) } label: { Text(ui: "Subject") }
            }
            .navigationTitle(Text(ui: "Details"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }

    /// Each address on its own line; tapping one opens its person card.
    private func people(_ addresses: [Address]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(addresses.prefix(100).enumerated()), id: \.offset) { _, address in
                Button { onPerson(address) } label: {
                    Text(verbatim: format(address)).multilineTextAlignment(.trailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityHint(Text(ui: "Opens the contact card"))
            }
        }
    }

    private func format(_ address: Address) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }
}
