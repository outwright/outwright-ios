// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `count` random bytes, eight from each draw: a byte at a time made the fuzzers spend
    /// their time making input rather than reading it.
    mutating func bytes(_ count: Int) -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            var word = next().littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0.prefix(count - data.count)) }
        }
        return data
    }
}

@Suite struct VCardFuzzTests {
    func check(_ data: Data) {
        do {
            let cards = try VCardReader.cards(data)
            #expect(cards.count <= DAVLimits.cardsPerResource)
            for card in cards {
                #expect(card.properties.count <= DAVLimits.vCardProperties)
                #expect((card.fields.photo?.count ?? 0) <= DAVLimits.photoBytes)
                _ = VCardWriter.write(card)
            }
        } catch {}
    }

    @Test func readerNeverTrapsOverArbitraryBytes() {
        var rng = SeededGenerator(state: 42)
        // Random bytes stop at the first line, so a few thousand cover what they can reach.
        for _ in 0..<2_000 {
            let count = Int.random(in: 0...8192, using: &rng)
            check(rng.bytes(count))
        }
        let fixtures: [Data] = [
            vcf(["FN:Bo", "N:Lind;Bo;;;", "EMAIL;TYPE=work:bo@example.org", "TEL;TYPE=cell:+4670", "ADR:;;S;L;R;P;C", "NOTE:a\\nb", "PHOTO:data:image/png;base64,AAAA"]),
            vcf(["NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=ISO-8859-1:=E5=E4=", "PHOTO;ENCODING=b:AAAA", "X;A=\"b^n:c"], version: "3.0"),
        ]
        for fixture in fixtures {
            for cut in stride(from: 0, to: fixture.count, by: 3) { check(fixture.prefix(cut)) }
            for _ in 0..<2_000 {
                var copy = fixture
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    copy[Int.random(in: 0..<copy.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                check(copy)
            }
        }
        check(vcf(Array(repeating: "EMAIL:a@example.org", count: 3_000)))
        check(vcf([String(repeating: "A", count: 300_000)]))
        check(Data(repeating: 0x3D, count: 100_000))
    }

    @Test func writeThenReadIsStable() throws {
        var rng = SeededGenerator(state: 7)
        let alphabet = Array("abcXYZ åäö漢,;:\\\n\"^ 1") + ["\r", "\t"]
        func text() -> String {
            String((0..<Int.random(in: 0...12, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        func label() -> String { ["", "work", "home", "cell"].randomElement(using: &rng) ?? "" }
        for _ in 0..<500 {
            var fields = VCardFields()
            fields.givenName = text()
            fields.familyName = text()
            fields.formattedName = text()
            fields.organization = text()
            fields.title = text()
            fields.note = text()
            fields.photo = Bool.random(using: &rng)
                ? Data((0..<Int.random(in: 1...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                : nil
            fields.emails = (0..<Int.random(in: 0...3, using: &rng)).map { _ in LabeledValue(label: label(), value: text()) }
            fields.phones = (0..<Int.random(in: 0...3, using: &rng)).map { _ in LabeledValue(label: label(), value: text()) }
            fields.addresses = (0..<Int.random(in: 0...2, using: &rng)).map { _ in
                VCardAddress(label: label(), street: text(), locality: text(), region: text(), postalCode: text(), country: text())
            }
            let base = try firstCard(vcf(["UID:x"], version: Bool.random(using: &rng) ? "4.0" : "3.0"))
            let written = VCardWriter.write(base.applying(fields))
            let first = try firstCard(written)
            let back = first.fields
            #expect(back.givenName == clean(fields.givenName))
            #expect(back.familyName == clean(fields.familyName))
            #expect(back.formattedName == clean(fields.formattedName))
            #expect(back.organization == clean(fields.organization))
            #expect(back.note == clean(fields.note))
            #expect(back.title == clean(fields.title))
            #expect(back.photo == fields.photo)
            #expect(back.emails.map(\.value) == fields.emails.map { clean($0.value) })
            #expect(back.phones.map(\.label) == fields.phones.map(\.label))
            #expect(back.addresses.map(\.street) == fields.addresses.map { clean($0.street) })
            #expect(try firstCard(VCardWriter.write(first)) == first)
        }
    }
}
