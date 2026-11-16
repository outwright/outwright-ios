// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import SwiftUI

/// Suggested people while a recipient is typed.
struct SuggestionList: View {
    let suggestions: [Address]
    let choose: (Address) -> Void

    var body: some View {
        List(suggestions, id: \.email) { person in
            Button {
                choose(person)
            } label: {
                HStack(spacing: 12) {
                    Avatar(name: person.name, email: person.email, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name ?? person.email)
                            .foregroundStyle(.primary)
                        if person.name != nil {
                            Text(person.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

/// The files attached, each opened with a tap (so a diagnostics report can be read before it is
/// sent) and each removable.
struct AttachmentChips: View {
    let model: ComposeModel
    @State private var opening: ShownAttachment?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 6) {
                        Button {
                            opening = ShownAttachment(attachment: attachment)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: Icons.attachment)
                                Text(attachment.filename)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            if model.attachments.indices.contains(index) { model.attachments.remove(at: index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(Text(ui: "Remove"))
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accentSoft, in: .capsule)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .opensAttachment($opening)
    }
}
