// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightSetup

struct PassphraseTests {
    @Test func wordListHas7776UniqueWords() throws {
        let words = try WordList.words()
        #expect(words.count == 7776)
        #expect(Set(words).count == 7776)
    }

    @Test func generatedPassphraseHasSixListedWords() throws {
        let list = Set(try WordList.words())
        let pass = try Passphrase.generate()
        #expect(pass.words.count == 6)
        #expect(pass.words.allSatisfy { list.contains($0) })
        #expect(try Passphrase.generate() != pass)
    }

    @Test func typedPassphraseForgivesCaseAndSpacing() throws {
        let pass = try Passphrase.generate()
        let messy = "  " + pass.words.map { $0.uppercased() }.joined(separator: " -  ") + " "
        #expect(try Passphrase(typed: messy) == pass)
        #expect(try Passphrase(typed: pass.display) == pass)
    }

    @Test func typedPassphraseRefusesUnlistedWordsAndWrongCount() throws {
        #expect(throws: SetupError.malformed) { try Passphrase(typed: "zzzz-abacus-abdomen-abdominal-abide-abiding") }
        #expect(throws: SetupError.malformed) { try Passphrase(typed: "abacus abdomen") }
    }

    @Test func generatedPassphrasesNeverHoldAHyphenatedWordAndTypeBack() throws {
        for _ in 0..<2000 {
            let pass = try Passphrase.generate()
            #expect(pass.words.allSatisfy { !$0.contains("-") })
            #expect(try Passphrase(typed: pass.display) == pass)
        }
    }

    @Test func printingNeverShowsTheWords() throws {
        let passphrase = try Passphrase.generate()
        var dumped = ""
        dump(passphrase, to: &dumped)
        for shown in [String(describing: passphrase), String(reflecting: passphrase), "\(passphrase)", dumped] {
            let tokens = Set(shown.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            #expect(tokens.isDisjoint(with: passphrase.words))
        }
    }
}
