// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

@Suite struct EntityTests {
    static let signed = Fixtures.data("""
    From: a@example.org
    Content-Type: multipart/signed; boundary="s1"; protocol="application/pgp-signature"; micalg=pgp-sha256

    --s1
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    caf=C3=A9
    --s1
    Content-Type: application/pgp-signature; name="signature.asc"
    Content-Transfer-Encoding: base64

    c2ln
    --s1--
    """)

    @Test func readsTheRootTypeAndItsDirectParts() throws {
        let entity = try MIMEParser.entity(Self.signed)
        #expect(entity.type == "multipart/signed")
        #expect(entity.parameters["protocol"] == "application/pgp-signature")
        #expect(entity.parts.map(\.type) == ["text/plain", "application/pgp-signature"])
        let text = try #require(entity.parts.first)
        #expect(text.raw == Fixtures.data(
            "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\ncaf=C3=A9"))
        #expect(text.body == Data("café".utf8))
        #expect(text.parameters["charset"] == "utf-8")
        #expect(entity.parts.last?.body == Data("sig".utf8))
        #expect(entity.parts.last?.headers.count == 2)
    }

    @Test func aPartIsReadWithoutPartsOfItsOwn() throws {
        let entity = try MIMEParser.entity(Fixtures.mixed)
        #expect(entity.type == "multipart/mixed")
        let first = try #require(entity.parts.first)
        #expect(first.type == "multipart/related")
        #expect(first.parts.isEmpty)
        #expect(try MIMEParser.entity(first.raw).parts.isEmpty == false)
    }

    @Test func aMessageWithoutContentTypeIsPlainText() throws {
        let entity = try MIMEParser.entity(Fixtures.data("From: a@example.org\n\nhello"))
        #expect(entity.type == "text/plain")
        #expect(entity.parts.isEmpty)
        #expect(entity.body == Data("hello".utf8))
    }

    @Test func entityIsBoundedLikeTheParser() {
        #expect(throws: MIMEError.tooLarge) { try MIMEParser.entity(Data(count: 70 << 20)) }
        #expect(throws: MIMEError.notAMessage) { try MIMEParser.entity(Data()) }
        var raw = "From: a@example.org\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n"
        for _ in 0..<20 { raw += "--b\r\n\r\nx\r\n" }
        var limits = MIMELimits.default
        limits.parts = 10
        #expect(throws: MIMEError.tooManyParts) { try MIMEParser.entity(Data(raw.utf8), limits: limits) }
    }

    @Test func entityNeverTrapsOnMutatedInput() {
        var rng = SplitMix64(state: 7)
        for _ in 0..<1_000 {
            let input = FuzzTests.mutate(Self.signed, kind: Int.random(in: 0..<5, using: &rng), &rng)
            do { _ = try MIMEParser.entity(input) } catch { _ = error }
        }
    }

    /// Arbitrary bytes, alone and behind a multipart header, read or refused without trapping, and
    /// never into more parts than the limit.
    @Test func entityOfArbitraryBytesNeverTraps() {
        var rng = SplitMix64(state: 11)
        var limits = MIMELimits.default
        limits.parts = 50
        let header = Data("Content-Type: multipart/mixed; boundary=b\r\n\r\n".utf8)
        let alphabet = Array("-b\r\n:; =AZaz09".utf8)
        for round in 0..<2_000 {
            let count = Int.random(in: 0...4_096, using: &rng)
            var bytes = (0..<count).map { _ in
                round.isMultiple(of: 2)
                    ? UInt8.random(in: 0...255, using: &rng) : alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
            }
            if round.isMultiple(of: 3) { bytes = [UInt8](header) + bytes }
            if let entity = try? MIMEParser.entity(Data(bytes), limits: limits) {
                #expect(entity.parts.count <= limits.parts)
                #expect(entity.raw.count <= bytes.count)
            }
        }
    }
}

