// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

/// The files of the mail with a person: three, and the rest behind Show all; a tap opens one.
struct PersonCardFiles: View {
    let files: [FileHit]
    let app: AppModel
    @State private var showsAll = false
    @State private var opening: ShownAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ui: "Files").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array((showsAll ? files : Array(files.prefix(3))).enumerated()), id: \.offset) { _, file in
                    Button {
                        if let attachment = SearchModel.attachment(file, in: app.store) {
                            opening = ShownAttachment(attachment: attachment)
                        } else {
                            // Its body is gone from the phone: the message opens, and fetches it.
                            app.personToShow = nil
                            app.selectedTab = .mail
                            app.messageToOpen = file.message.id
                        }
                    } label: {
                        HStack(spacing: 12) {
                            FileIcon(name: file.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: file.name).font(.body).lineLimit(1)
                                Text(verbatim: Self.byline(file)).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("card.file")
                    Divider().padding(.leading, 14)
                }
                if files.count > 3 {
                    Button { withAnimation { showsAll.toggle() } } label: {
                        Text(ui: showsAll ? "Show less" : "Show all")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Theme.accent)
                }
            }
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opensAttachment($opening)
    }

    /// The date and time of its message, and its size.
    static func byline(_ file: FileHit) -> String {
        let when = file.message.date.formatted(date: .abbreviated, time: .shortened)
        return when + " · " + ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }
}
