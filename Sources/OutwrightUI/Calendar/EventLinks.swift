// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The web links in an event's place or notes (a meeting link), shown as buttons that open only on
/// the owner's tap. Nothing is fetched to find them.
enum EventLinks {
    static let limit = 10
    /// How much of the text is looked through: the start of a long description is where links stand.
    static let scannedCharacters = 20_000

    /// `http` and `https` links with a host and no credentials, in order, each once, at most ten.
    static func find(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let scanned = String(text.prefix(scannedCharacters))
        var found: [URL] = []
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        for match in detector.matches(in: scanned, options: [], range: range) {
            guard found.count < limit else { break }
            guard let url = match.url, isWebLink(url), !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }

    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return false }
        return url.user() == nil && url.password() == nil
    }
}
