// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What fetching a published calendar gave.
public enum FeedAnswer: Sendable, Equatable {
    /// 304: what is held stands.
    case unchanged
    case body(Data, etag: String?, lastModified: String?)
}

/// Fetches a published calendar: one GET without credentials, conditional when the last answer
/// gave an ETag or Last-Modified (RFC 9110 › 13). HTTPS only; redirects only to HTTPS.
public struct FeedClient: Sendable {
    let http: HTTPClient

    public init(session: URLSession) {
        http = HTTPClient(credentials: nil, trustedHosts: nil, session: session)
    }

    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws(DAVError) -> FeedAnswer {
        var headers = ["Accept": "text/calendar"]
        if let etag { headers["If-None-Match"] = etag }
        if let lastModified { headers["If-Modified-Since"] = lastModified }
        let reply = try await http.send("GET", url, headers: headers)
        switch reply.status {
        case 200...299:
            return .body(reply.body, etag: reply.header("etag"), lastModified: reply.header("last-modified"))
        case 304: return .unchanged
        case 401, 403: throw .unauthorized
        case 404, 410: throw .notFound
        default: throw .status(reply.status)
        }
    }

    /// The address the owner typed, without white space (an address has none; a link broken across
    /// lines in a mail does), with `webcal://` read as `https://`; nil unless it is HTTPS with a host
    /// (plain HTTP to loopback only, for tests).
    public static func address(_ text: String) -> URL? {
        var trimmed = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        if trimmed.lowercased().hasPrefix("webcal://") {
            trimmed = "https://" + trimmed.dropFirst("webcal://".count)
        }
        guard let url = URL(string: trimmed), Hosts.schemeAllowed(url) else { return nil }
        return url
    }
}
