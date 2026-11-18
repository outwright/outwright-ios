// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

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

    /// The hosts of the common meeting services, each with every host under it. Data, not providers:
    /// a link is only recognised by where it goes.
    static let meetingHosts = [
        "teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "whereby.com", "meet.jit.si"
    ]

    /// The first https link that joins a meeting: one to a meeting service's host (or a host under it,
    /// on a dot boundary), or with `/join` in its path. Nil when there is none.
    static func meeting(in links: [URL]) -> URL? {
        links.first { url in
            guard url.scheme?.lowercased() == "https", isWebLink(url), let host = url.host()?.lowercased() else {
                return false
            }
            let known = meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            return known || url.path().lowercased().split(separator: "/").contains("join")
        }
    }

    /// How long before the start Join shows on the agenda.
    static let joinLead: TimeInterval = 15 * 60

    /// The occurrence's meeting link while it can be joined: from `joinLead` before its start until its end.
    static func joinable(_ occurrence: Occurrence, now: Date) -> URL? {
        guard now >= occurrence.start.addingTimeInterval(-joinLead), now < occurrence.end else { return nil }
        return meeting(in: find(in: occurrence.details.place + "\n" + occurrence.details.notes))
    }

    /// Characters a query value keeps as they are (RFC 3986's unreserved).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Maps searching for the place (`maps://?q=`); nil for a place with nothing to search or one that
    /// is a link. Opening it is the owner's tap; the app fetches nothing.
    static func maps(for place: String) -> URL? {
        let text = String(place.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !text.isEmpty, find(in: text).isEmpty,
            let query = text.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        return URL(string: "maps://?q=" + query)
    }

    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return false }
        return url.user() == nil && url.password() == nil
    }
}
