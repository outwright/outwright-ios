// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightMIME
public import WebKit

/// The locked web view a message is shown in: no script, nothing kept, nothing fetched until the
/// owner chooses Download pictures, and then pictures only. The rule list is what blocks loads;
/// the page's own Content Security Policy and DNS-prefetch switch are a second layer, which is why
/// the view shows nothing of the HTML when the rule list can't be compiled.
public enum ReadingConfiguration {
    /// One rule: block every load of every kind.
    public static let blockAllRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    /// The message's own attached pictures (`cid:`), served from memory: a rule list blocks custom
    /// schemes too, so they need an exception of their own.
    static let attachedPictures = #"{"trigger":{"url-filter":"^cid:"},"action":{"type":"ignore-previous-rules"}}"#
    /// Pictures written into the message (`data:`), of the four kinds a message may show. (A rule's
    /// filter has no alternation, so one rule each.)
    static let writtenInPictures = ["png", "jpeg", "gif", "webp"].map { type in
        #"{"trigger":{"url-filter":"^data:image/"# + type + #"[;,]"},"action":{"type":"ignore-previous-rules"}}"#
    }
    /// Pictures on the web, once the owner allowed them.
    static let remotePictures =
        #"{"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}"#

    /// Block everything but attached pictures; with remote pictures allowed, images over http and
    /// https too.
    public static func rules(allowRemote: Bool) -> String {
        let blockAll = String(blockAllRules.dropFirst().dropLast())
        let parts = [blockAll, attachedPictures] + writtenInPictures + (allowRemote ? [remotePictures] : [])
        return "[" + parts.joined(separator: ",") + "]"
    }

    /// A name for a rule list that changes whenever its rules do (FNV-1a over the UTF-8, in hex).
    static func fingerprint(_ rules: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rules.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    @MainActor
    public static func make(allowRemote: Bool, cidHandler: any WKURLSchemeHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        return configuration
    }

    /// The message's HTML with a policy in front: no script, no frames, no fonts, no fetches but
    /// pictures (attached ones always, remote ones once allowed), and a readable width. In dark mode
    /// its colours are turned for dark (`DarkColors`), unless the owner chose to see it as written,
    /// which is on white.
    public static func page(html: String, allowRemote: Bool, dark: Bool = false, adaptsColors: Bool = true) -> String {
        let turned = dark && adaptsColors
        let scheme = turned ? "dark" : "light"
        let background = dark && !adaptsColors ? "html { background: #fff; }" : ""
        let images = allowRemote ? "cid: data: http: https:" : "cid: data:"
        let policy =
            "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; "
            + "img-src \(images); style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; "
            + "media-src 'none'; form-action 'none'; base-uri 'none'"
        return """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(policy)">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="\(scheme)">
            <style>
            body { font: -apple-system-body; margin: 0; padding: 0 16px 16px; word-wrap: break-word; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100% !important; }
            \(background)
            </style></head><body>
            \(withoutDirectives(turned ? DarkColors.adapt(html) : html))
            </body></html>
            """
    }

    /// The message's HTML with every `<link` and `<meta` opening (and `</link`, `</meta`) renamed
    /// `<x-link`, `<x-meta`: unknown elements, which fetch nothing and show nothing, wherever they
    /// stand (in an attribute or a broken tag too), so neither can preconnect, prefetch or refresh
    /// before the owner allows anything. The page sets its own charset and viewport. Case does not
    /// matter; one linear pass.
    static func withoutDirectives(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "<", opensDirective(scalars, at: index) {
                let closing = index + 1 < scalars.count && scalars[index + 1] == "/"
                out.append(contentsOf: (closing ? "</x-" : "<x-").unicodeScalars)
                index += closing ? 2 : 1
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }

    /// Whether `link` or `meta` (after an optional `/`) follows the `<` at `start`, as a whole name.
    private static func opensDirective(_ scalars: [Unicode.Scalar], at start: Int) -> Bool {
        var index = start + 1
        if index < scalars.count, scalars[index] == "/" {
            index += 1
        }
        for name in ["link", "meta"] {
            let letters = Array(name.unicodeScalars)
            guard index + letters.count <= scalars.count else { continue }
            let matches = letters.indices.allSatisfy { offset in
                String(scalars[index + offset]).lowercased() == String(letters[offset])
            }
            guard matches else { continue }
            let after = index + letters.count
            guard after < scalars.count else { return true }
            let next = scalars[after]
            if next == ">" || next == "/" || next.properties.isWhitespace {
                return true
            }
        }
        return false
    }
}

/// Which links may be opened at all (after the owner has seen the real address).
public enum LinkPolicy {
    public static let schemes: Set<String> = ["http", "https", "mailto", "tel"]

    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }
}

/// Whether a message would fetch something from the web if allowed to: an `http:`/`https:`
/// address (with one slash or two, as browsers accept both) or a scheme-relative `//host` in a
/// picture attribute, any `srcset` candidate, or a CSS `url()`. Case does not matter.
public enum RemoteContent {
    private static let remote = #"(https?:|//)"#
    private static let attribute = #"(?i)\b(src|background|poster|lowsrc|dynsrc)\s*=\s*["']?\s*"# + remote
    private static let cssURL = #"(?i)url\(\s*["']?\s*"# + remote
    private static let srcset = #"(?i)\bsrcset\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#

    public static func mentionsRemote(_ html: String) -> Bool {
        if html.range(of: attribute, options: .regularExpression) != nil { return true }
        if html.range(of: cssURL, options: .regularExpression) != nil { return true }
        var rest = html[...]
        for _ in 0..<1_000 {
            guard let found = rest.range(of: srcset, options: .regularExpression) else { return false }
            if srcsetIsRemote(rest[found]) { return true }
            rest = rest[found.upperBound...]
        }
        return false
    }

    /// Every candidate of a `srcset="…"` attribute, by its address.
    private static func srcsetIsRemote(_ attribute: Substring) -> Bool {
        guard let equals = attribute.firstIndex(of: "=") else { return false }
        let value = attribute[attribute.index(after: equals)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
        return value.split(separator: ",").contains { candidate in
            let address = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return address.hasPrefix("http:") || address.hasPrefix("https:") || address.hasPrefix("//")
        }
    }
}

/// Serves `cid:` addresses from the message's own attachments.
@MainActor
public final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    private let byID: [String: (mimeType: String, data: Data)]

    public init(attachments: [Attachment]) {
        var map: [String: (mimeType: String, data: Data)] = [:]
        for attachment in attachments.prefix(1_000) {
            guard let cid = attachment.contentID else { continue }
            map[Self.normalize(cid)] = (attachment.mimeType, attachment.data)
        }
        byID = map
    }

    /// `<a@b>`, `a@b` and a percent-escaped `cid:` address all name the same part.
    nonisolated static func normalize(_ contentID: String) -> String {
        var text = contentID.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("cid:") { text = String(text.dropFirst(4)) }
        text = text.removingPercentEncoding ?? text
        if text.hasPrefix("<") { text = String(text.dropFirst()) }
        if text.hasSuffix(">") { text = String(text.dropLast()) }
        return text.lowercased()
    }

    func attachment(for url: URL?) -> (mimeType: String, data: Data)? {
        guard let url, url.scheme?.lowercased() == "cid" else { return nil }
        return byID[Self.normalize(url.absoluteString)]
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let found = attachment(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url, mimeType: found.mimeType, expectedContentLength: found.data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(found.data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
