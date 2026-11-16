// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightPush

/// RFC 8291 Section 5 and Appendix A, copied verbatim (whitespace removed).
private enum RFC8291 {
    static let body =
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
        + "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
        + "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    static let uaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
    static let uaPublic = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    static let authSecret = "BTBZMqHH6r4Tts7J_aSIgg"
    static let plaintext = "When I grow up, I want to be a watermelon"
}

private func base64url(_ text: String) throws -> Data {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.count % 4 != 0 {
        standard += "="
    }
    return try #require(Data(base64Encoded: standard))
}

private func vectorKeys(auth: Data? = nil) throws -> WebPushKeys {
    let raw = try base64url(RFC8291.uaPrivate) + (auth ?? base64url(RFC8291.authSecret))
    return try WebPushKeys(rawRepresentation: raw)
}

@Suite struct WebPushTests {
    @Test func rfc8291AppendixAVector() throws {
        let keys = try vectorKeys()
        #expect(keys.p256dh == RFC8291.uaPublic)
        #expect(keys.authString == RFC8291.authSecret)
        let plain = try decryptWebPush(base64url(RFC8291.body), keys: keys)
        #expect(String(bytes: plain, encoding: .utf8) == RFC8291.plaintext)
    }

    @Test func roundTripsKeys() throws {
        let keys = WebPushKeys.generate()
        let again = try WebPushKeys(rawRepresentation: keys.rawRepresentation)
        #expect(again.p256dh == keys.p256dh)
        #expect(again.authString == keys.authString)
        #expect(try base64url(keys.p256dh).count == 65)
        #expect(try base64url(keys.authString).count == 16)
        #expect(WebPushKeys.generate().p256dh != keys.p256dh)
    }

    @Test func rejectsBadRawRepresentation() {
        #expect(throws: PushError.crypto) { try WebPushKeys(rawRepresentation: Data()) }
        #expect(throws: PushError.crypto) { try WebPushKeys(rawRepresentation: Data(repeating: 0, count: 49)) }
    }

    @Test func wrongAuthFailsAsCrypto() throws {
        let keys = try vectorKeys(auth: Data(repeating: 7, count: 16))
        let body = try base64url(RFC8291.body)
        #expect(throws: PushError.crypto) { try decryptWebPush(body, keys: keys) }
    }

    @Test func rejectsOversizedBody() throws {
        let keys = try vectorKeys()
        var body = try base64url(RFC8291.body)
        body.append(Data(repeating: 0, count: 8 * 1024))
        #expect(throws: PushError.self) { try decryptWebPush(body, keys: keys) }
    }

    @Test func decryptNeverTrapsOnArbitraryBytes() throws {
        let keys = try vectorKeys()
        let vector = try base64url(RFC8291.body)
        var rng = SystemRandomNumberGenerator()
        for round in 0..<2_000 {
            let count = Int.random(in: 0...9_000, using: &rng)
            var body = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            // Every other body keeps a real header prefix so the parse reaches deeper.
            if round.isMultiple(of: 2) {
                let keep = min(Int.random(in: 0...vector.count, using: &rng), body.count)
                body.replaceSubrange(0..<keep, with: vector.prefix(keep))
            }
            do {
                _ = try decryptWebPush(body, keys: keys)
            } catch {
                #expect(error == .crypto || error == .malformed)
            }
        }
    }
}
