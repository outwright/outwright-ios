// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSetup

/// Typing the passphrase: suggestions from the word list.
extension SetupModel {
    /// Words of the list that begin with the word being typed (the last one, until a space).
    static func suggestions(for typed: String, limit: Int = 4) -> [String] {
        guard let last = typed.last, !last.isWhitespace, last != "-",
            let word = typed.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).last,
            let words = try? WordList.words()
        else { return [] }
        let found = words.lazy.filter { $0.hasPrefix(word) && !$0.contains("-") }.prefix(limit)
        // A word typed in full needs no suggestion of itself alone.
        return found.elementsEqual([String(word)]) ? [] : Array(found)
    }

    /// What was typed, its last word replaced by a suggestion, ready for the next word.
    static func completing(_ typed: String, with word: String) -> String {
        var kept = typed
        while let last = kept.last, !last.isWhitespace, last != "-" { kept.removeLast() }
        return kept + word + " "
    }
}
