// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import Testing

@testable import OutwrightUI

/// What VoiceOver hears for a row: every state the row shows, in the interface's language.
@Suite struct RowAccessibilityTests {
    private let english = Locale(identifier: "en_US")
    private let swedish = Locale(identifier: "sv_SE")

    private func row(
        read: Bool = true, flagged: Bool = false, attachment: Bool = false, invitation: Bool = false, count: Int = 1
    ) -> MessageRow {
        MessageRow(
            id: MessageID(raw: 1), accountID: AccountID(), folderID: FolderID(raw: 1), uid: 1,
            threadID: ThreadID(raw: "t"), from: Address(name: "Maja Ek", email: "maja@example.org"), to: [], cc: [],
            subject: "Board meeting", preview: "See you at seven.", date: Date(), isRead: read, isFlagged: flagged,
            hasAttachment: attachment, isInvitation: invitation, inboxClass: .focused, hasBody: false,
            threadCount: count)
    }

    private func label(_ row: MessageRow, _ locale: Locale) -> String {
        RowAccessibility.label(row, time: "7:53 PM", locale: locale)
    }

    @Test func namesSenderSubjectTimeAndPreview() {
        let text = label(row(), english)
        for part in ["Maja Ek", "Board meeting", "7:53 PM", "See you at seven."] {
            #expect(text.contains(part))
        }
    }

    enum State: CaseIterable, Sendable {
        case flagged, unread, attachment, invitation

        var key: String {
            switch self {
            case .flagged: "Flagged (row)"
            case .unread: "Unread (row)"
            case .attachment: "Has attachment (row)"
            case .invitation: "Invitation (row)"
            }
        }
    }

    private func row(with state: State) -> MessageRow {
        switch state {
        case .flagged: row(flagged: true)
        case .unread: row(read: false)
        case .attachment: row(attachment: true)
        case .invitation: row(invitation: true)
        }
    }

    @Test(arguments: State.allCases)
    func saysEachStateOnlyWhenTheRowHasIt(state: State) {
        for locale in [english, swedish] {
            let word = L10n.string(state.key, locale: locale)
            #expect(label(row(with: state), locale).contains(word), "\(state.key) in \(locale.identifier)")
            #expect(!label(row(), locale).contains(word), "no \(state.key) on a plain row in \(locale.identifier)")
        }
    }

    @Test func countsTheConversationOnlyWhenItHasSeveralMessages() {
        #expect(label(row(count: 3), english).contains("3"))
        #expect(label(row(count: 3), english) != label(row(count: 1), english))
        #expect(!label(row(count: 1), english).contains("1"))
    }

    @Test func speaksTheInterfaceLanguage() {
        let flagged = row(read: false, flagged: true, attachment: true, invitation: true, count: 2)
        #expect(label(flagged, english) != label(flagged, swedish))
        for state in State.allCases {
            let key = state.key
            #expect(L10n.string(key, locale: swedish) != L10n.string(key, locale: english), "\(key) has Swedish")
        }
    }
}
