// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// One conversation in the list: unread dot, avatar, sender and time, subject with its badges,
/// two lines of preview.
struct MessageRowView: View {
    let row: MessageRow
    let label: String
    /// The account's colour, shown when several accounts are listed together.
    var accountColor: Color?
    /// The folder the message is in, shown where mail from several folders is listed (search).
    var folderName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.isRead ? Color.clear : Theme.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 17)
            Avatar(name: row.from.name, email: row.from.email, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.from.name.flatMap { $0.isEmpty ? nil : $0 } ?? row.from.email)
                        .font(.title3)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 8) {
                    Text(row.subject.isEmpty ? String(localized: "(No subject)", bundle: .module) : row.subject)
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let folderName {
                        Text(verbatim: folderName)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.separator))
                            .lineLimit(1)
                    }
                    badges
                }
                if let notSent = row.notSent {
                    Text(notSent.reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.delete)
                        .lineLimit(2)
                }
                if !row.shownPreview().isEmpty {
                    Text(row.shownPreview())
                        .font(.body)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            if let accountColor {
                Capsule().fill(accountColor).frame(width: 3).padding(.vertical, 10).offset(x: -14)
            }
        }
        // The badges are pictures; the label says them in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: RowAccessibility.label(row, time: label, locale: Self.locale)))
    }

    /// The interface's language, which the spoken label follows.
    static var locale: Locale {
        Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
    }

    @ViewBuilder private var badges: some View {
        if row.isFlagged {
            Image(systemName: Icons.flag).foregroundStyle(Theme.flag).font(.subheadline)
        }
        if row.isInvitation {
            Image(systemName: Icons.meeting).foregroundStyle(Theme.secondaryText).font(.subheadline)
        }
        if row.hasAttachment {
            Image(systemName: Icons.attachment).foregroundStyle(Theme.secondaryText).font(.subheadline)
        }
        if row.threadCount > 1 {
            Text("\(row.threadCount)")
                .font(.subheadline)
                .foregroundStyle(row.isRead ? Theme.secondaryText : Theme.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(row.isRead ? Color.clear : Theme.accentSoft)
                        .stroke(row.isRead ? Theme.separator : Color.clear, lineWidth: 1))
        }
    }
}
