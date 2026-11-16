// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

@Suite struct EventLinksTests {
    @Test func findsHttpsMeetingLink() {
        let found = EventLinks.find(in: "Video call: https://meet.example.org/j/123?pwd=abc\nDial in +46 8 555 010 20")
        #expect(found.map(\.absoluteString) == ["https://meet.example.org/j/123?pwd=abc"])
        #expect(EventLinks.find(in: "see http://intranet.example.org/room").count == 1)
    }

    @Test func ignoresOtherSchemes() {
        let text = "javascript:alert(1) file:///etc/passwd tel:+46855501020 mailto:bo@example.org ftp://example.org/x"
        #expect(EventLinks.find(in: text).isEmpty)
    }

    @Test func keepsAtMostTenAndNoRepeats() {
        let text = (0..<30).map { "https://example.org/\($0 % 15)" }.joined(separator: " ")
        let found = EventLinks.find(in: text)
        #expect(found.count == 10)
        #expect(Set(found).count == 10)
    }

    @Test func survivesArbitraryText() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let scalars = (0..<Int.random(in: 0..<300, using: &generator)).compactMap { _ in
                UnicodeScalar(UInt32.random(in: 0..<0x2_0000, using: &generator))
            }
            let text = String(String.UnicodeScalarView(scalars))
            #expect(EventLinks.find(in: text).allSatisfy { ["http", "https"].contains($0.scheme ?? "") })
        }
    }
}
