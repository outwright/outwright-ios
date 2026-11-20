// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct FuzzTests {
    /// Line ranges of the lines that start with "--" (multipart delimiters).
    static func delimiterLines(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
            if bytes[start] == 0x2D, start + 1 < bytes.count, bytes[start + 1] == 0x2D { ranges.append(start..<end) }
            start = end
        }
        return ranges
    }

    static func mutate(_ seed: Data, kind: Int, _ rng: inout SplitMix64) -> Data {
        var bytes = [UInt8](seed)
        switch kind {
        case 0:
            return Data((0..<Int.random(in: 0..<600, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        case 1:
            for _ in 0..<Int.random(in: 1..<12, using: &rng) where !bytes.isEmpty {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
        case 2:
            bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
        default:
            guard let line = delimiterLines(bytes).randomElement(using: &rng) else { return seed }
            var cut = line
            if kind == 4 {
                let before = Int.random(in: 0...min(40, line.lowerBound), using: &rng)
                let after = Int.random(in: 0...min(40, bytes.count - line.upperBound), using: &rng)
                cut = (line.lowerBound - before)..<(line.upperBound + after)
            }
            bytes.removeSubrange(cut)
        }
        return Data(bytes)
    }

    @Test func parserNeverThrowsUnboundedOrTraps() {
        var rng = SplitMix64(state: 42)
        let quoted = Data(("From: Bob <\"a b\"@example.org>\r\nTo: \"a\\\"b\"@example.org, \"ab\"@example.org,"
            + " a @ example.org\r\nCc: \"x \\\\ y\"@ä.example\r\n\r\nHi\r\n").utf8)
        let seeds = [Fixtures.alternative, Fixtures.mixed, quoted]
        let previewHeaders = [
            "Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n",
            "Content-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n",
            "Content-Type: text/html\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n",
            "Content-Transfer-Encoding: base64\r\n\r\n",
            "",
        ].map { Data($0.utf8) }
        for _ in 0..<2_000 {
            let seed = seeds[Int.random(in: 0..<seeds.count, using: &rng)]
            let input = Self.mutate(seed, kind: Int.random(in: 0..<5, using: &rng), &rng)
            do { _ = try MIMEParser.parse(input) } catch { _ = error }
            do { _ = try MIMEParser.parseHeaders(input) } catch { _ = error }
            let headers = previewHeaders[Int.random(in: 0..<previewHeaders.count, using: &rng)]
            #expect(Preview.text(fromPartial: input, headers: headers).count <= 200)
        }
    }

    @Test func hugeBufferIsRefused() {
        let big = Data(count: 70 << 20)
        #expect(throws: MIMEError.tooLarge) { try MIMEParser.parse(big) }
        #expect(Preview.text(fromPartial: big.prefix(1 << 20), headers: Data()).count <= 200)
    }

    @Test func deepNestingIsBounded() {
        func nest(_ level: Int) -> String {
            guard level < 500 else { return "leaf\r\n" }
            return "Content-Type: multipart/mixed; boundary=\"b\(level)\"\r\n\r\n--b\(level)\r\n"
                + nest(level + 1) + "\r\n--b\(level)--\r\n"
        }
        let raw = "From: a@example.org\r\n" + nest(0)
        #expect(throws: MIMEError.tooDeep) { try MIMEParser.parse(Data(raw.utf8)) }
    }
}

/// The calendar part of hostile messages.
extension FuzzTests {
    @Test func invitationMutationsNeverTrapAndStayWithinTheCap() {
        var rng = SplitMix64(state: 6_047)
        let seeds = [Fixtures.outlookInvitation, Fixtures.icsAttachment(method: "REQUEST"),
                     Fixtures.icsAttachment(method: "CANCEL"), Fixtures.icsAttachment(method: "REPLY")]
        for _ in 0..<3_000 {
            let seed = seeds[Int.random(in: 0..<seeds.count, using: &rng)]
            let input = Self.mutate(seed, kind: Int.random(in: 1..<5, using: &rng), &rng)
            do {
                let m = try MIMEParser.parse(input)
                #expect((m.calendar?.data.count ?? 0) <= MIMELimits.default.calendarPartBytes)
                #expect(m.isInvitation == (m.calendar?.isInvitation ?? false))
            } catch { _ = error }
            do { _ = try MIMEParser.parseHeaders(input) } catch { _ = error }
        }
    }

    @Test func aCalendarPartAtTheCapIsReadAndOneByteMoreIsNot() throws {
        let small = MIMELimits(calendarPartBytes: 16)
        let raw = { (body: String) in
            Fixtures.data("From: a@example.org\nContent-Type: text/calendar; method=REQUEST\n\n" + body)
        }
        #expect(try MIMEParser.parse(raw(String(repeating: "a", count: 16)), limits: small).calendar != nil)
        #expect(try MIMEParser.parse(raw(String(repeating: "a", count: 17)), limits: small).calendar == nil)
    }

    @Test func tenThousandMultipartsAroundACalendarAreBounded() {
        let leaf = "Content-Type: text/calendar; method=REQUEST\r\n\r\nBEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
        // Nested: the outermost level first, joined once.
        let levels = 0..<10_000
        let openings = levels.reversed().map {
            "Content-Type: multipart/mixed; boundary=\"n\($0)\"\r\n\r\n--n\($0)\r\n"
        }
        let closings = levels.map { "\r\n--n\($0)--\r\n" }
        let nested = (openings + [leaf] + closings).joined()
        #expect(throws: MIMEError.tooDeep) { try MIMEParser.parse(Data(("From: a@example.org\r\n" + nested).utf8)) }
        // Side by side: past the part limit.
        var siblings = "From: a@example.org\r\nContent-Type: multipart/mixed; boundary=\"s\"\r\n\r\n"
        for _ in 0..<10_000 { siblings += "--s\r\n" + leaf }
        siblings += "--s--\r\n"
        #expect(throws: MIMEError.tooManyParts) { try MIMEParser.parse(Data(siblings.utf8)) }
    }
}
