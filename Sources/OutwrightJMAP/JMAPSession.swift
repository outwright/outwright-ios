// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightNet
import Synchronization

/// Where a JMAP server lives, after discovery (RFC 8620 section 2).
struct JMAPEndpoint: Sendable {
    let scheme: String
    let host: String
    let port: Int?

    var effectivePort: Int { port ?? (scheme == "https" ? 443 : 80) }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// Parses "host" or "host:port"; plain http only for loopback.
    init(_ text: String) throws(JMAPError) {
        guard let parts = URLComponents(string: "x://" + text), let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.path.isEmpty, parts.query == nil
        else {
            throw .malformed
        }
        self.host = host.lowercased()
        port = parts.port
        scheme = Self.loopbackHosts.contains(self.host) ? "http" : "https"
    }

    /// True when the URL is on this host with a scheme that is https (or loopback http).
    func owns(_ url: URL) -> Bool {
        guard let urlHost = url.host?.lowercased(), urlHost == host, let urlScheme = url.scheme,
            urlScheme == "https" || (urlScheme == "http" && Self.loopbackHosts.contains(host))
        else {
            return false
        }
        return (url.port ?? (urlScheme == "https" ? 443 : 80)) == effectivePort
    }

    var wellKnown: URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = port
        parts.path = "/.well-known/jmap"
        return parts.url
    }
}

/// Follows at most `limit` redirects, and only to the same host.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let remaining: Mutex<Int>
    private let endpoint: JMAPEndpoint
    private let authorization: String

    init(limit: Int, endpoint: JMAPEndpoint, authorization: String) {
        remaining = Mutex(limit)
        self.endpoint = endpoint
        self.authorization = authorization
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = remaining.withLock { count -> Bool in
            guard count > 0 else {
                return false
            }
            count -= 1
            return true
        }
        guard allowed, let url = request.url, endpoint.owns(url) else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
}
