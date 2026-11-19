// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

@Suite struct DarkColorsTests {
    private func turned(_ css: String) throws -> RGBA {
        let inverted = try #require(DarkColors.inverted(css))
        return try #require(RGBA(inverted))
    }

    private func lightness(_ css: String) throws -> Double {
        let color = try turned(css)
        return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    @Test func darkTurnsLightAndLightTurnsDark() throws {
        #expect(try lightness("#000") > 0.9)
        #expect(try lightness("white") < 0.1)
        #expect(try lightness("rgb(32, 32, 32)") > 0.4)
    }

    @Test func aColourKeepsItsHue() throws {
        let navy = try turned("navy")
        #expect(navy.blue > navy.red && navy.blue > navy.green)
        let translucent = try turned("rgba(0, 0, 0, 0.5)")
        #expect(translucent.alpha == 0.5)
    }

    @Test func coloursChangeWhereColoursAreWritten() {
        let html = """
            <font color="#111111">a</font><table bgcolor=white><tr><td style="color: black; width: 3px">b</td>
            <style>p { background-color: #fff }</style>
            """
        let turned = DarkColors.adapt(html)
        #expect(!turned.contains("#111111"))
        #expect(!turned.contains("bgcolor=white"))
        #expect(!turned.contains("color: black"))
        #expect(!turned.contains("#fff }"))
        #expect(turned.contains("width: 3px"))
    }

    @Test func everythingButColoursStaysAsItIs() {
        let html = """
            <p id="black">Write #fff or red here.</p><a href="https://example.org/#000">x</a>
            <!-- color: #000 --><div style="font-family: Red; background: url(#000)"></div>
            <style>#fff, .black > p { width: 1px } @media (max-width: 600px) { a:hover { margin: 0 } }</style>
            """
        #expect(DarkColors.adapt(html) == html)
    }

    @Test func aSheetsNestedRulesAreTurnedToo() {
        let turned = DarkColors.adapt("<style>@media screen { a:hover { color: #000; } }</style>")
        #expect(turned.contains("@media screen { a:hover {"))
        #expect(!turned.contains("#000"))
    }

    @Test func arbitraryTextNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("<>/\"'=;:{}()#!-*abcdefrgbcolorstylebgcolorurl0123456789 \n\té")
        for _ in 0..<3_000 {
            let length = Int.random(in: 0..<200, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "<" })
            _ = DarkColors.adapt(text)
        }
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0..<300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = DarkColors.adapt(String(decoding: bytes, as: UTF8.self))
        }
    }
}
