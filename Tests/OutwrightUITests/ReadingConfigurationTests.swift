// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import Testing
import WebKit

@testable import OutwrightUI

@MainActor @Suite struct ReadingConfigurationTests {
    private func rules(_ json: String) throws -> [[String: Any]] {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [[String: Any]])
    }

    @Test func lockedConfigurationBlocksEverything() throws {
        let handler = CIDSchemeHandler(attachments: [])
        let configuration = ReadingConfiguration.make(allowRemote: false, cidHandler: handler)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(configuration.websiteDataStore.isPersistent == false)
        #expect(configuration.urlSchemeHandler(forURLScheme: "cid") != nil)

        let blocking = try rules(ReadingConfiguration.blockAllRules)
        #expect(blocking.count == 1)
        let trigger = try #require(blocking.first?["trigger"] as? [String: Any])
        let action = try #require(blocking.first?["action"] as? [String: Any])
        #expect(trigger["url-filter"] as? String == ".*")
        #expect(trigger.count == 1, "no resource-type or domain narrows it: every resource is blocked")
        #expect(action["type"] as? String == "block")
    }

    /// The filters of every exception after the first rule (which blocks everything).
    private func exceptions(_ json: String) throws -> [String] {
        let list = try rules(json)
        #expect(list.first?["action"] as? [String: String] == ["type": "block"])
        return try list.dropFirst().map { rule in
            #expect((rule["action"] as? [String: String])?["type"] == "ignore-previous-rules")
            let trigger = try #require(rule["trigger"] as? [String: Any])
            return try #require(trigger["url-filter"] as? String)
        }
    }

    /// A content rule list blocks custom schemes too, so the message's own attached pictures and
    /// the pictures written into it (PNG, JPEG, GIF, WebP) get exceptions, and nothing else does.
    @Test func lockedRulesLetOnlyAttachedAndWrittenInPicturesThrough() throws {
        let filters = try exceptions(ReadingConfiguration.rules(allowRemote: false))
        let matches = { (url: String) in
            filters.contains { url.range(of: $0, options: .regularExpression) != nil }
        }
        #expect(matches("cid:logo@example.org"))
        for type in ["png", "jpeg", "gif", "webp"] {
            #expect(matches("data:image/\(type);base64,AAAA"))
        }
        #expect(!matches("data:image/svg+xml;base64,AAAA"))
        #expect(!matches("data:text/html,<b>x</b>"))
        #expect(!matches("https://img.example.org/a.png"))
    }

    @Test func allowingRemoteLetsOnlyImagesThrough() throws {
        let allowing = try rules(ReadingConfiguration.rules(allowRemote: true))
        let remote = try #require(allowing.first { rule in
            ((rule["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("https?") == true
        })
        let trigger = try #require(remote["trigger"] as? [String: Any])
        #expect(trigger["resource-type"] as? [String] == ["image"])
        #expect(try exceptions(ReadingConfiguration.rules(allowRemote: true)).count
            == (try exceptions(ReadingConfiguration.rules(allowRemote: false)).count) + 1)
    }

    /// The rule lists compile: a list that doesn't leaves the message unshown (fail closed).
    @Test(arguments: [false, true]) func ruleListsCompile(allowRemote: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let list = try await store.compileContentRuleList(
            forIdentifier: "test", encodedContentRuleList: ReadingConfiguration.rules(allowRemote: allowRemote))
        #expect(list != nil)
    }

    @Test func pageLeavesOutTheMessagesLinksAndMetaDirectives() {
        let html = #"""
            <LINK rel="preconnect" href="https://t.example.org"><link rel=dns-prefetch href=//t.example.org/>
            <meta http-equiv="refresh" content="0;url=https://t.example.org"><Meta HTTP-EQUIV=Refresh content=1>
            <p title="a > b">Hej</p><linkage>stays</linkage>
            """#
        let page = ReadingConfiguration.page(html: html, allowRemote: false).lowercased()
        let own = ReadingConfiguration.page(html: "", allowRemote: false).lowercased()
        // Only the page's own meta tags are tags; the message's are text.
        #expect(page.components(separatedBy: "<meta").count == own.components(separatedBy: "<meta").count)
        #expect(!page.contains("<link rel"))
        #expect(page.contains(#"<p title="a > b">hej</p>"#))
        #expect(page.contains("<linkage>stays</linkage>"))
        #expect(page.contains("content-security-policy"))
    }

    @Test func pageForbidsScriptsAndRemoteLoadsUntilAllowed() {
        let locked = ReadingConfiguration.page(html: "<p>Hej</p>", allowRemote: false)
        let open = ReadingConfiguration.page(html: "<p>Hej</p>", allowRemote: true)
        #expect(locked.contains("script-src 'none'"))
        #expect(locked.contains("img-src cid: data:;"))
        #expect(open.contains("img-src cid: data: http: https:;"))
        #expect(locked.contains("<p>Hej</p>"))
        #expect(locked.contains(#"<meta http-equiv="x-dns-prefetch-control" content="off">"#))
    }

    @Test func remotePicturesAreNoticed() {
        #expect(RemoteContent.mentionsRemote(#"<img src="https://img.example.org/a.png">"#))
        #expect(RemoteContent.mentionsRemote(#"<td background='http://x.example.org/b.gif'>"#))
        #expect(RemoteContent.mentionsRemote(#"<div style="background:url( https://x.example.org/c.png)">"#))
        #expect(RemoteContent.mentionsRemote(#"<img SRC=//x.example.org/d.png>"#))
        #expect(RemoteContent.mentionsRemote(#"<img src="https:/x.example.org/e.png">"#))
        #expect(RemoteContent.mentionsRemote(#"<img src='HTTP:/x.example.org/f.png'>"#))
        #expect(RemoteContent.mentionsRemote(#"<img src="//x.example.org/g.png">"#))
        #expect(RemoteContent.mentionsRemote(#"<img srcset="cid:a@example.org 1x, https://x.example.org/h.png 2x">"#))
        #expect(RemoteContent.mentionsRemote(#"<IMG SRCSET="cid:a@example.org 1x,//x.example.org/i.png 2x">"#))
        #expect(!RemoteContent.mentionsRemote(#"<img src="cid:logo@example.org"> <a href="https://example.org">"#))
        #expect(!RemoteContent.mentionsRemote(#"<img srcset="cid:a@example.org 1x, data:image/png;base64,AA 2x">"#))
    }

    @Test func linksOpenOnlyForSafeSchemes() throws {
        for text in ["https://example.org", "http://example.org", "mailto:bo@example.org", "tel:+4612345"] {
            #expect(LinkPolicy.isOpenable(try #require(URL(string: text))))
        }
        for text in ["javascript:alert(1)", "file:///etc/passwd", "cid:x", "ftp://example.org", "data:text/html,x"] {
            #expect(!LinkPolicy.isOpenable(try #require(URL(string: text))))
        }
    }

    @Test func cidHandlerFindsInlineAttachmentsByContentID() {
        let logo = Attachment(
            filename: "logo.png", mimeType: "image/png", contentID: "<logo@example.org>", isInline: true,
            data: Data([1, 2, 3]))
        let handler = CIDSchemeHandler(attachments: [logo])
        #expect(handler.attachment(for: URL(string: "cid:logo@example.org"))?.data == Data([1, 2, 3]))
        #expect(handler.attachment(for: URL(string: "cid:other@example.org")) == nil)
    }

    @Test func contentIDsMatchWhateverTheirCaseAndEscaping() {
        let plain = CIDSchemeHandler.normalize("<Logo.Part@Example.org>")
        #expect(CIDSchemeHandler.normalize("cid:logo.part@example.org") == plain)
        #expect(CIDSchemeHandler.normalize("CID:Logo.Part%40Example.org") == plain)
        #expect(CIDSchemeHandler.normalize("  <logo.part@example.org>  ") == plain)
        #expect(CIDSchemeHandler.normalize("cid:other@example.org") != plain)
    }

    @Test func htmlAndMarkupAttachmentsStayOutOfQuickLook() {
        func attachment(_ name: String, _ type: String) -> OutwrightMIME.Attachment {
            Attachment(filename: name, mimeType: type, contentID: nil, isInline: false, data: Data())
        }
        #expect(AttachmentFiles.presentation(attachment("a.html", "text/html")) == .lockedWeb)
        #expect(AttachmentFiles.presentation(attachment("a.HTM", "application/octet-stream")) == .lockedWeb)
        #expect(AttachmentFiles.presentation(attachment("logo.svg", "image/svg+xml")) == .text)
        #expect(AttachmentFiles.presentation(attachment("x.bin", "image/svg+xml")) == .text)
        #expect(AttachmentFiles.presentation(attachment("feed.xml", "application/xml")) == .text)
        #expect(AttachmentFiles.presentation(attachment("page.xhtml", "application/xhtml+xml")) == .text)
        #expect(AttachmentFiles.presentation(attachment("report.pdf", "application/pdf")) == .quickLook)
        #expect(AttachmentFiles.presentation(attachment("photo.jpg", "image/jpeg")) == .quickLook)
    }

    @Test func plainTextOfHTMLLeavesOutStylesScriptsAndTheHead() {
        let html = "<html><head><title>Secret title</title><style>p { color: red }</style></head>"
            + "<body><script>alert(1)</script><p>Hej</p><STYLE>.x{}</STYLE>då</body></html>"
        let text = RichText.plain(fromHTML: html)
        #expect(text.contains("Hej"))
        #expect(text.contains("då"))
        #expect(!text.contains("Secret"))
        #expect(!text.contains("color"))
        #expect(!text.contains("alert"))
        #expect(!text.contains(".x"))
    }

    @Test func theHTMLCleanersSurviveArbitraryText() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("<>/\"' =linkmetastylescripthead-equivLINKMETA\n\té")
        for _ in 0..<2_000 {
            let length = Int.random(in: 0..<200, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "<" })
            let cleaned = ReadingConfiguration.withoutDirectives(text)
            #expect(cleaned.count <= text.count * 4)
            #expect(HTMLText.removingHiddenElements(text).count <= text.count)
            _ = RichText.plain(fromHTML: text)
        }
    }

    @Test func quickLookGetsOnlySafeKindsByTheNameItIsGiven() {
        func shown(_ name: String, _ type: String = "application/octet-stream") -> AttachmentFiles.Presentation {
            AttachmentFiles.presentation(
                OutwrightMIME.Attachment(filename: name, mimeType: type, contentID: nil, isInline: false, data: Data()))
        }
        // What Quick Look would be handed decides, not the name as sent.
        #expect(shown("x.html ") == .lockedWeb)
        #expect(shown(String(repeating: "a", count: 115) + ".html" + String(repeating: "b", count: 20) + ".pdf")
            == .lockedWeb)
        #expect(shown("PAGE.HTML", "application/pdf") == .lockedWeb)
        for blocked in ["a.htm", "a.shtml", "a.svg", "a.xml", "a.webarchive", "a.mht", "a.mhtml", "a.bin", "a"] {
            #expect(shown(blocked) != .quickLook, "\(blocked)")
        }
        for safe in ["r.PDF", "p.jpg", "p.HEIC", "n.txt", "d.docx", "s.xlsx", "k.pptx", "v.mov", "a.m4a"] {
            #expect(shown(safe) == .quickLook, "\(safe)")
        }
        #expect(shown("r.pdf", "text/html") == .lockedWeb)
    }

    @Test func everyLinkAndMetaOpeningIsNeutralisedWhereverItStands() {
        let long = String(repeating: "x", count: 4_100)
        let cases = [
            #"<meta content="\#(long)" http-equiv=refresh content="0;url=https://t.example.org">"#,
            #"<p x=a"><link rel=preconnect href=https://t.example.org>"#,
            #"<p "><link rel=preconnect href=https://t.example.org>"#,
            #"<LINK rel=prefetch href=https://t.example.org><MeTa http-equiv=refresh>"#,
            #"<link rel=preload href="https://t.example.org/\#(long)"></link >"#,
        ]
        for html in cases {
            let page = ReadingConfiguration.withoutDirectives(html).lowercased()
            #expect(!page.contains("<link"))
            #expect(!page.contains("<meta"))
            #expect(!page.contains("</link"))
        }
        #expect(ReadingConfiguration.withoutDirectives("<linkage>stays</linkage>") == "<linkage>stays</linkage>")
    }

    @Test func aNewslettersHeadTagsLeaveNoTextInTheBody() {
        let html = """
            <meta charset="utf-8"><META name="viewport" content="width=device-width">
            <link rel="stylesheet" href="https://t.example.org/s.css"><Link REL=icon href=/f.ico />
            <p>Nyheter</p>
            """
        let page = ReadingConfiguration.withoutDirectives(html).lowercased()
        for shown in ["<meta", "&lt;meta", "&lt;link", "<link", "</link"] {
            #expect(!page.contains(shown), "\(shown)")
        }
        #expect(page.contains("<p>nyheter</p>"))
    }

    /// #9: a name ending in a dot has no extension, so it never reaches Quick Look.
    @Test func aNameEndingInADotStaysOutOfQuickLook() {
        func attachment(_ name: String) -> OutwrightMIME.Attachment {
            Attachment(filename: name, mimeType: "application/pdf", contentID: nil, isInline: false, data: Data())
        }
        #expect(AttachmentFiles.presentation(attachment("report.pdf.")) == .text)
        #expect(AttachmentFiles.presentation(attachment("report.")) == .text)
        #expect(AttachmentFiles.presentation(attachment("report.pdf")) == .quickLook)
    }

    /// #10: the file Quick Look shows stays until another is opened; then only the new one is left.
    @Test func anOpenedFileStaysUntilTheNextIsOpened() throws {
        let first = try #require(AttachmentFiles.write(
            Attachment(filename: "a.pdf", mimeType: "application/pdf", contentID: nil, isInline: false, data: Data([1]))))
        #expect(FileManager.default.fileExists(atPath: first.path))
        let second = try #require(AttachmentFiles.write(
            Attachment(filename: "b.pdf", mimeType: "application/pdf", contentID: nil, isInline: false, data: Data([2]))))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        AttachmentFiles.remove(second)
    }

    /// #11: a picture a mixed message's HTML names by `cid:` is shown in it and not listed again,
    /// even without multipart/related.
    @Test(arguments: ["", "Content-Disposition: inline\r\n", "Content-Disposition: attachment; filename=logo.png\r\n"])
    func aPictureNamedByCIDInAMixedMessageIsShownNotListed(disposition: String) throws {
        let raw = "From: bo@example.org\r\nSubject: Logo\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n"
            + "--m\r\nContent-Type: text/html\r\n\r\n<p>Hej <img src=\"cid:logo@example.org\"></p>\r\n"
            + "--m\r\nContent-Type: image/png\r\nContent-ID: <logo@example.org>\r\n\(disposition)"
            + "Content-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo=\r\n--m--\r\n"
        let content = MessageContent(try MIMEParser.parse(Data(raw.utf8)))
        let handler = CIDSchemeHandler(attachments: content.attachments)
        #expect(handler.attachment(for: URL(string: "cid:logo@example.org"))?.mimeType == "image/png")
        #expect(content.files.isEmpty)
    }

    /// #11: only a picture is hidden by its `cid:`; a document the HTML happens to name stays listed.
    @Test func aDocumentNamedByCIDStaysListed() throws {
        let raw = "From: bo@example.org\r\nSubject: Avtal\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n"
            + "--m\r\nContent-Type: text/html\r\n\r\n<p>Se <a href=\"cid:avtal@example.org\">avtalet</a></p>\r\n"
            + "--m\r\nContent-Type: application/pdf\r\nContent-ID: <avtal@example.org>\r\n"
            + "Content-Disposition: attachment; filename=avtal.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n--m--\r\n"
        let content = MessageContent(try MIMEParser.parse(Data(raw.utf8)))
        #expect(content.files.map(\.filename) == ["avtal.pdf"])
    }
}
