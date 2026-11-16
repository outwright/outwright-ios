// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightMIME

@Suite struct IDNATests {
    /// RFC 3492's own samples and well-known IDN domains.
    @Test(arguments: [
        ("bücher.example", "xn--bcher-kva.example"),
        ("münchen.de", "xn--mnchen-3ya.de"),
        ("räksmörgås.se", "xn--rksmrgs-5wao1o.se"),
        ("例え.テスト", "xn--r8jz45g.xn--zckzah"),
    ])
    func aNonASCIIDomainBecomesItsALabels(_ domain: String, _ expected: String) {
        #expect(MailAddress.asciiDomain(domain) == expected)
    }

    @Test func anASCIIDomainStaysAsItIs() {
        #expect(MailAddress.asciiDomain("Mail.Example.org") == "Mail.Example.org")
    }

    @Test func upperCaseAndDecomposedLettersAreNormalisedFirst() {
        #expect(MailAddress.asciiDomain("BÜCHER.example") == "xn--bcher-kva.example")
        #expect(MailAddress.asciiDomain("bu\u{308}cher.example") == "xn--bcher-kva.example")
    }

    @Test func aLabelTooLongForDNSHasNoASCIIForm() {
        #expect(MailAddress.asciiDomain(String(repeating: "ö", count: 70) + ".example") == nil)
    }

    @Test func anAddressKeepsItsLocalPartAndGetsAnASCIIDomain() {
        #expect(MailAddress.ascii("jörgen@räksmörgås.se") == "jörgen@xn--rksmrgs-5wao1o.se")
        #expect(MailAddress.ascii("bo@example.org") == "bo@example.org")
        #expect(MailAddress.ascii("no-domain") == "no-domain")
    }

    @Test func arbitraryTextNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 0..<80, using: &generator)
            let scalars = (0..<length).compactMap { _ in
                Unicode.Scalar(UInt32.random(in: 0..<0x11_0000, using: &generator))
            }
            var text = String(String.UnicodeScalarView(scalars))
            if Bool.random(using: &generator) { text = "a@" + text }
            _ = MailAddress.ascii(text)
            _ = MailAddress.asciiDomain(text)
        }
    }

    /// A domain in a written header goes as its A-labels, which every server reads.
    @Test func aWrittenHeaderCarriesTheASCIIDomain() throws {
        let message = OutgoingMessage(
            from: Address(name: nil, email: "j@example.org"),
            to: [Address(name: "Bo", email: "bo@räksmörgås.se")],
            cc: [], bcc: [], subject: "Hi", textBody: "Hello", htmlBody: nil, attachments: [],
            inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000),
            messageID: "out1@example.org")
        let written = String(bytes: try MIMEWriter.write(message, includeBcc: false), encoding: .utf8) ?? ""
        #expect(written.contains("To: Bo <bo@xn--rksmrgs-5wao1o.se>\r\n"))
    }
}
