// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// EFF's large word list (7 776 words, CC BY 3.0 US), the dice-number column stripped.
public enum WordList {
    private static let cached = Result { try load() }
    private static let cachedSet = Result { Set(try load()) }

    /// The same words as a set, built once.
    static func wordSet() throws(SetupError) -> Set<String> {
        switch cachedSet {
        case .success(let set): return set
        case .failure: throw .malformed
        }
    }

    public static func words() throws(SetupError) -> [String] {
        switch cached {
        case .success(let words): return words
        case .failure: throw .malformed
        }
    }

    private static func load() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "eff_large_wordlist", withExtension: "txt") else {
            throw SetupError.malformed
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var words: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count == 2 else { throw SetupError.malformed }
            words.append(String(columns[1]))
        }
        guard words.count == 7776 else { throw SetupError.malformed }
        return words
    }
}

/// The generated passphrase that protects a setup file: six words from the list (about 77 bits).
/// Generation skips the four hyphenated words of the list (drop-down, felt-tip, t-shirt, yo-yo),
/// because the hyphen separates the words when typed; 7 772 words remain.
public struct Passphrase: Sendable, Equatable {
    public static let wordCount = 6

    public let words: [String]

    public static func generate() throws(SetupError) -> Passphrase {
        let list = try WordList.words().filter { !$0.contains("-") }
        var generator = SystemRandomNumberGenerator()
        var chosen: [String] = []
        for _ in 0..<wordCount {
            guard let word = list.randomElement(using: &generator) else { throw .malformed }
            chosen.append(word)
        }
        return Passphrase(words: chosen)
    }

    /// Reads what the owner typed: case, spaces and hyphens do not matter; every word must be in the list.
    public init(typed: String) throws(SetupError) {
        let list = try WordList.wordSet()
        let parts = typed.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        guard parts.count == Passphrase.wordCount, parts.allSatisfy({ list.contains($0) }) else { throw .malformed }
        self.words = parts
    }

    private init(words: [String]) { self.words = words }

    public var display: String { words.joined(separator: "-") }
}

/// Printing, `String(reflecting:)` and `dump` show nothing of the words; `display` is for the
/// screen that shows them and the copy button.
extension Passphrase: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Passphrase(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
