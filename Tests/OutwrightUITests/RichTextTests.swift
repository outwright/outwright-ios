// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import Testing

@testable import OutwrightUI

@Suite struct RichTextTests {
    @Test func bulletContinuesOnReturnAndStopsOnEmpty() throws {
        let typed = try #require(ListEditing.continued(old: AttributedString("• Mjölk"), new: AttributedString("• Mjölk\n")))
        #expect(String(typed.text.characters) == "• Mjölk\n• ")
        #expect(typed.cursor == typed.text.characters.count)

        let stopped = try #require(
            ListEditing.continued(old: AttributedString("• Mjölk\n• "), new: AttributedString("• Mjölk\n• \n")))
        #expect(String(stopped.text.characters) == "• Mjölk\n")
        #expect(stopped.cursor == stopped.text.characters.count)

        let numbered = try #require(ListEditing.continued(old: AttributedString("1. Ett"), new: AttributedString("1. Ett\n")))
        #expect(String(numbered.text.characters) == "1. Ett\n2. ")

        #expect(ListEditing.continued(old: AttributedString("Hej"), new: AttributedString("Hej\n")) == nil)
        #expect(ListEditing.continued(old: AttributedString("• a"), new: AttributedString("• ab")) == nil)
    }

    @Test func listsAreSentAsHTMLLists() throws {
        let html = try #require(RichText.html(AttributedString("Att köpa:\n• Mjölk\n• Bröd\nSedan:\n1. Ett\n2. Två")))
        #expect(html.contains("<ul><li>Mjölk</li><li>Bröd</li></ul>"))
        #expect(html.contains("<ol><li>Ett</li><li>Två</li></ol>"))
        let back = RichText.attributed(fromHTML: html)
        #expect(String(back.characters) == "Att köpa:\n• Mjölk\n• Bröd\nSedan:\n1. Ett\n2. Två")
    }

    /// The quote's cleaner reads the original's HTML, which anyone can write: whatever it is given,
    /// nothing that runs or fetches on its own comes out. The values are read as a browser reads them.
    @Test func cleaningArbitraryHTMLNeverLeavesAnythingThatRuns() {
        let pieces = [
            "<", ">", "/", "\"", "'", "=", " ", "script", "SCRIPT", "iframe", "object", "embed", "form", "base",
            "meta", "link", "onload", "onClick", "href", "src", "srcset", "javascript:", "java\tscript:", "&#106;",
            "&#106", "&#x6A", "&#0000000000106;", "&colon;", "&Tab;", "vbscript:", "<!--", "-->", "<p>", "</p>",
            "body", "<b>", "x", "\u{0}", "é", "<a ", "style", "</blockquote>", "</div>", "<plaintext>", "<xmp>", "/>", "<div", "<table/>", "<embed>",
            String(repeating: " ", count: 300)
        ]
        let seed = UInt64.random(in: 0...UInt64.max)
        print("cleaningArbitraryHTML seed \(seed)")
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<2_000 {
            let count = Int.random(in: 0..<60, using: &generator)
            let html = (0..<count).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
            let cleaned = QuoteCleaner.clean(html).lowercased()
            // An element of another name (`<linkx>`) is nothing a reader runs.
            let dropped = #"<(script|iframe|object|embed|form|base|meta|link|plaintext|xmp)[\s/>]"#
            #expect(cleaned.range(of: dropped, options: .regularExpression) == nil, "seed \(seed): \(html)")
            #expect(Self.isBalanced(cleaned), "seed \(seed): \(html)")
            for (name, value) in attributes(cleaned) {
                #expect(!name.hasPrefix("on"), "seed \(seed): \(html)")
                let read = Self.asABrowserReads(value)
                #expect(!read.contains("javascript:") && !read.contains("vbscript:"), "seed \(seed): \(html)")
            }
        }
        for _ in 0..<500 {
            let data = Data((0..<Int.random(in: 0..<400, using: &generator)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            })
            _ = QuoteCleaner.clean(String(decoding: data, as: UTF8.self))
        }
    }

    /// Ways a script address hides from a reader that looks for it plainly.
    @Test func hiddenScriptAddressesAreDropped() {
        let hidden = [
            "&#0000000000106;avascript:alert(1)", "&#106avascript:alert(1)", "&#x6Aavascript:alert(1)",
            String(repeating: " ", count: 5_000) + "javascript:alert(1)", "javascript&colon;alert(1)",
            "JaVaScRiPt:alert(1)", "java&Tab;script:alert(1)"
        ]
        for value in hidden {
            let cleaned = QuoteCleaner.clean("<a href=\"\(value)\">x</a><img srcset=\"a.png 1x, \(value) 2x\">")
            #expect(!cleaned.contains("href"), "\(value)")
            #expect(!cleaned.contains("srcset"), "\(value)")
        }
        let kept = QuoteCleaner.clean(
            "<a href=\"https://example.org/a?b=c\">x</a><a href=\"mailto:bo@example.org\">y</a>"
                + "<img src=\"cid:pic@example.org\"><a href=\"page.html\">z</a>")
        for value in ["https://example.org/a?b=c", "mailto:bo@example.org", "cid:pic@example.org", "page.html"] {
            #expect(cleaned(kept, holds: value))
        }
        #expect(!QuoteCleaner.clean("<img src=\"ftp://example.org/x.png\">").contains("src"))
    }

    private func cleaned(_ html: String, holds value: String) -> Bool {
        html.contains("\"\(value)\"")
    }

    /// The original can't close the quote it is put in, nor turn what follows into its own text, nor
    /// leave an element open with a self-closing slash a browser ignores.
    @Test func theOriginalStaysInsideItsQuote() {
        let originals = [
            "<div><b>Hej</div></blockquote></div><p>x<plaintext>rest<xmp>y</xmp>",
            "<blockquote/>inner", "<b/>leak", "<a href=\"https://evil.example.org\"/>linked", "<table/>tbl"
        ]
        for original in originals {
            let cleaned = QuoteCleaner.clean(original)
            #expect(!cleaned.contains("</blockquote></div>"), "\(cleaned)")
            #expect(!cleaned.lowercased().contains("plaintext"))
            #expect(!cleaned.lowercased().contains("xmp"))
            #expect(Self.isBalanced(cleaned), "\(cleaned) from \(original)")
        }
    }

    /// A void element loses only its tag: what follows it stays.
    @Test func aVoidElementLosesOnlyItsTag() {
        for tag in ["<embed src=\"https://example.org/x.swf\">", "<frame src=\"x.html\">", "<embed/>"] {
            let cleaned = QuoteCleaner.clean("<p>a\(tag)rest of the original</p>")
            #expect(cleaned == "<p>arest of the original</p>", "\(tag)")
        }
    }

    /// A picture in `data:` is shown only where a picture goes, and never as SVG, which can run.
    @Test func dataPicturesOnlyWherePicturesGo() {
        #expect(!QuoteCleaner.clean("<a href=\"data:image/png;base64,AAAA\">x</a>").contains("href"))
        #expect(!QuoteCleaner.clean("<a href=\"data:image/svg+xml,<svg onload=alert(1)>\">x</a>").contains("href"))
        #expect(!QuoteCleaner.clean("<img src=\"data:image/svg+xml;base64,PHN2Zz4=\">").contains("src"))
        #expect(!QuoteCleaner.clean("<img src=\"DATA:IMAGE/SVG+XML,x\">").contains("src"))
        #expect(QuoteCleaner.clean("<img src=\"data:image/png;base64,AAAA\">").contains("src=\"data:image/png"))
    }

    /// CSS escapes can't hide a script or an expression in a style.
    @Test func cssEscapesDontHideScriptInAStyle() {
        let hidden = [
            "background:url(java\\73 cript:alert(1))", "width:expr\\65 ssion(alert(1))",
            "width:expre\\ssion(alert(1))", "-moz-binding:url(x.xml#y)", "background:url(vb\\73 cript:x)"
        ]
        for style in hidden {
            #expect(!QuoteCleaner.clean("<div style=\"\(style)\">x</div>").contains("style"), "\(style)")
        }
        #expect(QuoteCleaner.clean("<div style=\"color:red\">x</div>").contains("style=\"color:red\""))
    }

    /// A picture left out goes by its exact Content-ID, and nothing else of the HTML with it.
    @Test func aPictureLeftOutGoesByItsExactID() {
        let html = "<p><img src=\"cid:small@example.org\"> see cid:big@example.org here</p><p>next</p>"
            + "<p><img src=\"cid:big@example.org\"><img src=\"cid:big@example.org.extra\"></p>"
        let cleaned = QuoteCleaner.clean(html, droppingPictures: ["big@example.org"])
        #expect(cleaned == "<p><img src=\"cid:small@example.org\" /> see cid:big@example.org here</p><p>next</p>"
            + "<p><img src=\"cid:big@example.org.extra\" /></p>")
        let parts = ["small@example", "small@example.org", "big@example.org"].map {
            Attachment(filename: "p.png", mimeType: "image/png", contentID: $0, isInline: true, data: Data())
        }
        #expect(QuotedOriginal.shown(by: cleaned, of: parts).compactMap(\.contentID) == ["small@example.org"])
    }

    /// A Content-ID with characters HTML escapes, spaces around the address, or percent escapes
    /// (RFC 2392) is still the same picture: shown, and dropped, by it.
    @Test func contentIDsAreReadAsABrowserReadsThem() {
        let cases: [(html: String, id: String)] = [
            ("<img src='cid:a\"b@x'>", "a\"b@x"),
            ("<img src=\"cid:a&lt;b&gt;@x\">", "a<b>@x"),
            ("<img src=\"cid:a&apos;b@x\">", "a'b@x"),
            ("<img src=\"  cid:pic@x \">", "pic@x"),
            ("<img src=\"cid:pic%40x\">", "pic@x")
        ]
        for (html, id) in cases {
            let part = Attachment(filename: "p.png", mimeType: "image/png", contentID: id, isInline: true, data: Data())
            let cleaned = QuoteCleaner.clean(html)
            #expect(QuotedOriginal.shown(by: cleaned, of: [part]).count == 1, "\(html)")
            #expect(QuoteCleaner.clean(html, droppingPictures: [id]).isEmpty, "\(html)")
        }
        let bad = Attachment(filename: "p.png", mimeType: "image/png", contentID: "pic%4", isInline: true, data: Data())
        #expect(QuotedOriginal.shown(by: QuoteCleaner.clean("<img src=\"cid:pic%4\">"), of: [bad]).isEmpty)
    }

    /// A picture left out goes from every attribute that shows it, not only an `<img>`'s src.
    @Test func aPictureLeftOutGoesFromEveryPlaceItShows() {
        let html = "<table background=\"cid:big@x\"><tr><td>t</td></tr></table>"
            + "<img srcset=\"cid:big@x 2x, cid:small@x 1x\"><video poster=\"cid:big@x\"></video>"
        let cleaned = QuoteCleaner.clean(html, droppingPictures: ["big@x"])
        #expect(!cleaned.contains("big@x"), "\(cleaned)")
        #expect(cleaned.contains("cid:small@x 1x"))
        #expect(cleaned.contains("<td>t</td>"))
    }

    /// A percent escape is `%` and two hex digits; a sign is not a digit.
    @Test func aPercentEscapeTakesOnlyHexDigits() {
        #expect(QuoteAttributes.contentID(of: "cid:pic%40x") == "pic@x")
        #expect(QuoteAttributes.contentID(of: "cid:pic%+1x") == nil)
        #expect(QuoteAttributes.contentID(of: "cid:pic%-1x") == nil)
        #expect(QuoteAttributes.contentID(of: "cid:pic% 1x") == nil)
    }

    /// Only an attribute that shows a picture sends its part: a `cid:` in an alt or title text does not.
    @Test func onlyPictureAttributesSendTheirPart() {
        let part = Attachment(filename: "p.png", mimeType: "image/png", contentID: "x@y", isInline: true, data: Data())
        for html in ["<img alt=\"cid:x@y\">", "<a title=\"cid:x@y\">t</a>", "<img data-src=\"cid:x@y\">"] {
            #expect(QuotedOriginal.shown(by: QuoteCleaner.clean(html), of: [part]).isEmpty, "\(html)")
        }
        for html in ["<img src=\"cid:x@y\">", "<td background=\"cid:x@y\">t</td>", "<img srcset=\"a.png 1x, cid:x@y 2x\">"] {
            #expect(QuotedOriginal.shown(by: QuoteCleaner.clean(html), of: [part]).count == 1, "\(html)")
        }
    }

    /// A picture left out goes from a style that shows it too; a style showing another picture stays.
    @Test func aPictureLeftOutGoesFromAStyle() {
        for style in ["background:url(cid:big@x)", "background: url( 'cid:big@x' )", "background:URL(cid\\3A big@x)"] {
            let cleaned = QuoteCleaner.clean("<div style=\"\(style)\">t</div>", droppingPictures: ["big@x"])
            #expect(!cleaned.contains("big@x"), "\(cleaned)")
            #expect(cleaned.contains(">t</div>"))
        }
        let kept = QuoteCleaner.clean("<div style=\"background:url(cid:small@x)\">t</div>", droppingPictures: ["big@x"])
        #expect(kept.contains("cid:small@x"))
    }

    /// A picture named as a bare string in an `image-set` is found too, and dropped with the style.
    @Test func aPictureInAnImageSetGoesFromAStyle() {
        let found = Set(QuoteAttributes.styleContentIDs(
            "background:image-set(\"cid:a@x\" 1x, url(cid:b@x) 2x); mask:-webkit-image-set('cid:c@x' 1x)"))
        #expect(found == ["a@x", "b@x", "c@x"])
        for style in ["background:image-set('cid:big@x' 1x)", "background:-WEBKIT-image-set( 'cid\\3A big@x' 2x)"] {
            let cleaned = QuoteCleaner.clean("<div style=\"\(style)\">t</div>", droppingPictures: ["big@x"])
            #expect(!cleaned.contains("big@x"), "\(cleaned)")
        }
    }

    /// A picture a style shows (a background) is sent with the quote, as it is dropped by it.
    @Test func aPictureAStyleShowsIsSent() {
        let part = Attachment(filename: "p.png", mimeType: "image/png", contentID: "x@y", isInline: true, data: Data())
        let styles = ["<div style=\"background:url(cid:x@y)\">t</div>",
                      "<td style=\"background:image-set('cid:x@y' 1x)\">t</td>"]
        for html in styles {
            #expect(QuotedOriginal.shown(by: QuoteCleaner.clean(html), of: [part]).count == 1, "\(html)")
        }
        let text = QuoteCleaner.clean("<div style=\"color:red\">cid:x@y</div>")
        #expect(QuotedOriginal.shown(by: text, of: [part]).isEmpty)
    }

    /// A self-closed `<svg/>` or `<math/>` holds nothing: what follows it stays.
    @Test func aSelfClosedSVGKeepsWhatFollows() {
        #expect(QuoteCleaner.clean("<p>a<svg/>after svg</p>") == "<p>aafter svg</p>")
        #expect(QuoteCleaner.clean("<p>a<math />after math</p>") == "<p>aafter math</p>")
        #expect(!QuoteCleaner.clean("<p>a<svg><script>x</script></svg>b</p>").contains("script"))
    }

    /// Whether every element that isn't void is closed, in order, and none is closed that wasn't opened.
    private static func isBalanced(_ html: String) -> Bool {
        let void: Set<String> = ["br", "img", "hr", "wbr", "area", "col", "source", "track", "param", "keygen"]
        var open: [String] = []
        for tag in html.lowercased().matches(of: #/<(/?)([a-z0-9]+)[^>]*>/#) {
            let name = String(tag.output.2)
            if void.contains(name) { continue }
            if tag.output.1.isEmpty {
                open.append(name)
            } else if open.popLast() != name {
                return false
            }
        }
        return open.isEmpty
    }

    /// An attribute value as a browser reads it: references decoded (any digits, the semicolon
    /// optional), tabs and line breaks gone, lower-case.
    private static func asABrowserReads(_ value: String) -> String {
        var text = value
        let named = ["&colon;": ":", "&tab;": "\t", "&newline;": "\n"]
        for (name, character) in named {
            text = text.replacingOccurrences(of: name, with: character, options: .caseInsensitive)
        }
        text = text.replacing(#/&#([xX][0-9a-fA-F]+|[0-9]+);?/#) { match in
            let digits = match.output.1
            let number = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        return String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 0x20 })
            .lowercased()
    }

    /// The attributes of the tags in cleaned HTML, where every value is written in double quotes.
    private func attributes(_ html: String) -> [(name: String, value: String)] {
        html.matches(of: #/<[a-z][^>]*>/#).flatMap { tag in
            tag.output.matches(of: #/\s([^\s="<>]+)(?:="([^"]*)")?/#).map { (String($0.output.1), String($0.output.2 ?? "")) }
        }
    }
}
