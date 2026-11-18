// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import Testing

@testable import OutwrightModel

private struct StubOpening: MessageOpening {
    let answer: OpenedMessage?
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? { answer }
}

/// Answers only for the account it was made for.
private struct AccountOpening: MessageOpening {
    let account: String
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        guard account == self.account, let message = try? MIMEParser.parse(raw, limits: limits) else { return nil }
        return OpenedMessage(message: message, facts: ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil))
    }
}

/// SplitMix64: the same bytes for the same seed, so a failing round can be run again.
private struct SeededBytes: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct MessageReaderTests {
    @Test func smimeEnvelopedIsEncryptedShape() {
        let raw = Data("Content-Type: application/pkcs7-mime; smime-type=enveloped-data; name=smime.p7m\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(raw))
    }

    @Test func smimeOpaqueSignedIsNotEncryptedShape() {
        let raw = Data("Content-Type: application/pkcs7-mime; smime-type=signed-data\r\n\r\nMIIB".utf8)
        #expect(!MessageReader.isEncryptedShape(raw))
    }

    @Test func smimeWithoutTypeIsEncryptedByItsP7mName() {
        let named = Data("Content-Type: application/x-pkcs7-mime; name=\"smime.p7m\"\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(named))
        let bare = Data("Content-Type: application/x-pkcs7-mime\r\n\r\nMIIB".utf8)
        #expect(!MessageReader.isEncryptedShape(bare))
    }

    @Test func p7mNameIsReadAsTheParserReadsParameters() {
        let extended = Data("Content-Type: application/pkcs7-mime; name*=utf-8''smime.p7m\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(extended))
        let continued = Data("Content-Type: application/pkcs7-mime; name*0=\"smime\"; name*1=\".p7m\"\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(continued))
        let quoted = Data("Content-Type: application/pkcs7-mime; name=\"a;b.p7m\"\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(quoted))
        let typed = Data("Content-Type: application/pkcs7-mime; smime-type*=us-ascii''enveloped-data\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(typed))
        let signedNamedP7m = Data(
            "Content-Type: application/pkcs7-mime; smime-type=\"signed-data\"; name=smime.p7m\r\n\r\nMIIB".utf8)
        #expect(!MessageReader.isEncryptedShape(signedNamedP7m))
    }

    @Test func authEnvelopedIsEncryptedShape() {
        let raw = Data("Content-Type: application/pkcs7-mime; smime-type=authEnveloped-data\r\n\r\nMIIB".utf8)
        #expect(MessageReader.isEncryptedShape(raw))
    }

    @Test func firstOpeningThatAnswersWins() throws {
        let raw = Data("From: a@example.org\r\nSubject: s\r\n\r\nhi".utf8)
        let message = try MIMEParser.parse(raw, limits: .default)
        let facts = ProtectionFacts(
            decryption: .decrypted, signature: .none, resentBy: nil, protection: ProtectionID(raw: "b"))
        let openings: [any MessageOpening] = [
            StubOpening(answer: nil), StubOpening(answer: OpenedMessage(message: message, facts: facts)),
            StubOpening(answer: OpenedMessage(message: message, facts: nil))
        ]
        let opened = MessageReader.read(raw, limits: .default, openings: openings)
        #expect(opened?.facts?.protection == ProtectionID(raw: "b"))
        #expect(MessageReader.read(raw, limits: .default, openings: [])?.facts == nil)
    }

    /// Remote content is fetched from decrypted text only when nobody on the way could have
    /// changed it (EFAIL): the opening vouches for its integrity, else pictures stay shut.
    @Test func remoteContentNeedsIntegrityOnDecryptedContent() {
        #expect(ProtectionFacts(decryption: .none, signature: .none, resentBy: nil).allowsRemoteContent)
        #expect(ProtectionFacts(decryption: .failed, signature: .none, resentBy: nil).allowsRemoteContent)
        #expect(!ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil).allowsRemoteContent)
        #expect(!ProtectionFacts(decryption: .unreadable, signature: .none, resentBy: nil).allowsRemoteContent)
        #expect(!ProtectionFacts(
            decryption: .decrypted, signature: .valid(verified: true), resentBy: nil).allowsRemoteContent)
        #expect(ProtectionFacts(
            decryption: .decrypted, signature: .none, resentBy: nil, contentIntegrity: true).allowsRemoteContent)
    }

    @Test func openingsAreToldTheAccount() {
        let raw = Data("From: a@example.org\r\nSubject: s\r\n\r\nhi".utf8)
        let openings: [any MessageOpening] = [AccountOpening(account: "a")]
        #expect(MessageReader.read(raw, limits: .default, openings: openings, account: "a")?.facts != nil)
        #expect(MessageReader.read(raw, limits: .default, openings: openings, account: "b")?.facts == nil)
        #expect(MessageReader.read(raw, limits: .default, openings: openings)?.facts == nil)
    }

    @Test func encryptedShapeNeverTrapsOnArbitraryBytes() throws {
        let seed: UInt64 = 0x0081_5EED
        var rng = SeededBytes(state: seed)
        let starts = [
            "Content-Type: application/pkcs7-mime; smime-type=", "Content-Type: application/x-pkcs7-mime; name=\"",
            "Content-Type: application/pkcs7-mime; name*0*=", "Content-Type: multipart/encrypted;;==\"\";"
        ]
        for round in 0..<400 {
            var bytes = Data(starts[round % starts.count].utf8)
            for _ in 0..<Int.random(in: 0...256, using: &rng) { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            let random = Data((0..<Int.random(in: 0...512, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            for input in [bytes, random] {
                // The bytes and the headers read from them are judged alike.
                let headers = try? MIMEParser.parseHeaders(input)
                #expect(
                    MessageReader.isEncryptedShape(input) == (headers.map(MessageReader.isEncryptedShape) ?? false),
                    "seed \(seed), round \(round)")
            }
        }
    }
}
