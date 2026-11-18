// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// What VoiceOver says for a row of the mail list: everything the row shows, its badges too
/// (unread, flagged, attachment, invitation, the conversation's size), in the given language.
enum RowAccessibility {
    static func label(_ row: MessageRow, time: String, locale: Locale) -> String {
        var parts: [String] = []
        if !row.isRead {
            parts.append(L10n.string("Unread (row)", locale: locale))
        }
        parts.append(row.from.name.flatMap { $0.isEmpty ? nil : $0 } ?? row.from.email)
        parts.append(row.subject.isEmpty ? L10n.string("(No subject)", locale: locale) : row.subject)
        parts.append(time)
        if row.isFlagged {
            parts.append(L10n.string("Flagged (row)", locale: locale))
        }
        if row.isProtected {
            parts.append(L10n.string("Encrypted (row)", locale: locale))
        }
        if row.hasAttachment {
            parts.append(L10n.string("Has attachment (row)", locale: locale))
        }
        if row.isInvitation {
            parts.append(L10n.string("Invitation (row)", locale: locale))
        }
        if row.threadCount > 1 {
            let format = L10n.string("%lld messages (row)", locale: locale)
            parts.append(String(format: format, locale: locale, Int64(row.threadCount)))
        }
        if let notSent = row.notSent {
            parts.append(notSent.reason)
        }
        let preview = row.shownPreview(locale: locale)
        if !preview.isEmpty {
            parts.append(preview)
        }
        return parts.joined(separator: ", ")
    }
}
