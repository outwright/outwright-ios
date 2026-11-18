// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Bulleted ("• ") and numbered ("1. ") lines in the body: Return on an item starts the next one,
/// Return on an empty item ends the list. They are sent as `<ul>` and `<ol>` (`RichText.html`).
enum ListEditing {
    enum Kind: Equatable {
        case bullet, numbered
    }

    /// A line's list mark: its kind, its number (numbered lines) and its length in characters.
    struct Marker: Equatable {
        var kind: Kind
        var number: Int
        var length: Int

        var next: String {
            kind == .bullet ? ListEditing.bullet : "\(number + 1). "
        }
    }

    static let bullet = "• "

    /// The edit made and where the cursor goes, in characters from the start.
    struct Edit: Equatable {
        var text: AttributedString
        var cursor: Int
    }

    /// The mark a line starts with, if any.
    static func marker(of line: some StringProtocol) -> Marker? {
        if line.hasPrefix(bullet) { return Marker(kind: .bullet, number: 0, length: 2) }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let number = Int(digits),
            line.dropFirst(digits.count).hasPrefix(". ")
        else { return nil }
        return Marker(kind: .numbered, number: number, length: digits.count + 2)
    }

    /// When `new` is `old` with one line break typed at the end of a list item: the next item's mark
    /// after it, or, when the item was empty, the list ended (its mark gone, no new line). Nil for
    /// any other edit.
    static func continued(old: AttributedString, new: AttributedString) -> Edit? {
        let before = Array(old.characters)
        let after = Array(new.characters)
        guard after.count == before.count + 1 else { return nil }
        let typed = zip(before, after).prefix { $0 == $1 }.count
        guard after.indices.contains(typed), after[typed] == "\n",
            after[(typed + 1)...].elementsEqual(before[typed...])
        else { return nil }
        let lineStart = (before[..<typed].lastIndex(of: "\n") ?? -1) + 1
        let lineEnd = before[typed...].firstIndex(of: "\n") ?? before.count
        guard let mark = marker(of: String(before[lineStart..<typed])) else { return nil }
        if lineEnd - lineStart == mark.length, typed == lineEnd {
            // Return on an empty item: the list ends here, and the line is left empty.
            var text = old
            let chars = text.characters
            guard let start = chars.index(chars.startIndex, offsetBy: lineStart, limitedBy: chars.endIndex),
                let end = chars.index(start, offsetBy: mark.length, limitedBy: chars.endIndex)
            else { return nil }
            text.removeSubrange(start..<end)
            return Edit(text: text, cursor: lineStart)
        }
        var text = new
        let chars = text.characters
        guard let after = chars.index(chars.startIndex, offsetBy: typed + 1, limitedBy: chars.endIndex) else {
            return nil
        }
        text.insert(AttributedString(mark.next), at: after)
        return Edit(text: text, cursor: typed + 1 + mark.next.count)
    }

    /// Starts or ends a list on the line holding `offset`: its mark is removed when it has this
    /// kind, else put in its place (a numbered line counts on from the line above).
    static func toggle(_ kind: Kind, at offset: Int, in text: inout AttributedString) {
        let chars = Array(text.characters)
        let point = min(max(offset, 0), chars.count)
        let lineStart = (chars[..<point].lastIndex(of: "\n") ?? -1) + 1
        let lineEnd = chars[lineStart...].firstIndex(of: "\n") ?? chars.count
        let current = marker(of: String(chars[lineStart..<lineEnd]))
        var mark: String?
        if current?.kind != kind {
            switch kind {
            case .bullet:
                mark = bullet
            case .numbered:
                let above = lineStart > 0 ? (chars[..<(lineStart - 1)].lastIndex(of: "\n") ?? -1) + 1 : nil
                let previous = above.flatMap { marker(of: String(chars[$0..<(lineStart - 1)])) }
                mark = "\((previous?.kind == .numbered ? previous?.number ?? 0 : 0) + 1). "
            }
        }
        let view = text.characters
        guard let start = view.index(view.startIndex, offsetBy: lineStart, limitedBy: view.endIndex),
            let end = view.index(start, offsetBy: current?.length ?? 0, limitedBy: view.endIndex)
        else { return }
        text.replaceSubrange(start..<end, with: AttributedString(mark ?? ""))
    }
}
