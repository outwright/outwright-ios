// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightNet

/// Microsoft Graph v1.0 over HTTPS with a bearer token. Every request stays on the base URL's
/// scheme, host and port (`@odata.nextLink` included); redirects are not followed; answers are
/// capped at `maxAnswer` bytes and listings at `maxPages` pages and `maxListing` bytes in all. A
/// 401 asks `renew` once and, with the token it refused and, when it says so, is tried again with a
/// fresh one.
public struct GraphClient: Sendable {
    static let maxAnswer = 4 << 20
    static let maxPages = 200
    /// All the pages of one listing together.
    static let maxListing = 32 << 20

    let base: URL
    private let session: URLSession
    private let token: @Sendable () async throws(GraphError) -> String
    private let renew: @Sendable (String) async -> Bool

    /// `token` hands out the current access token; `renew` drops the refused one it is given and
    /// says whether to ask `token` for another.
    public init(
        base: URL, session: URLSession = .shared,
        token: @escaping @Sendable () async throws(GraphError) -> String,
        renew: @escaping @Sendable (String) async -> Bool
    ) {
        self.base = base
        self.session = session
        self.token = token
        self.renew = renew
    }

    /// `path` (with `query`) under the base URL.
    func url(_ path: String, query: [(String, String)] = []) throws(GraphError) -> URL {
        guard let joined = URL(string: path, relativeTo: base)?.absoluteURL,
            var parts = URLComponents(url: joined, resolvingAgainstBaseURL: false)
        else {
            throw .malformed
        }
        if !query.isEmpty {
            parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = parts.url else {
            throw .malformed
        }
        return url
    }

    /// The body of a 2xx answer to `method` on `url`, of at most `limit` bytes.
    func send(
        _ method: String, _ url: URL, body: Data? = nil, ifMatch: String? = nil, prefer: String? = nil,
        contentType: String = "application/json", accept: String = "application/json", limit: Int = maxAnswer
    ) async throws(GraphError) -> Data {
        try check(url)
        for attempt in 0..<2 {
            let bearer = try await token()
            var request = Self.request(method, url, bearer: bearer, body: body, ifMatch: ifMatch)
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if let prefer {
                request.setValue(prefer, forHTTPHeaderField: "Prefer")
            }
            let (status, data) = try await fetch(request, limit: limit)
            if (200..<300).contains(status) {
                return data
            }
            guard status == 401, attempt == 0, await renew(bearer) else {
                throw Self.failure(status)
            }
        }
        throw .unauthorized
    }

    private static func request(
        _ method: String, _ url: URL, bearer: String, body: Data?, ifMatch: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + HeaderValue.clean(bearer), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch {
            request.setValue(HeaderValue.clean(ifMatch), forHTTPHeaderField: "If-Match")
        }
        return request
    }

    /// What a status other than 2xx means.
    private static func failure(_ status: Int) -> GraphError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .conflict
        case 412: .preconditionFailed
        case 429, 503: .throttled
        default: .status(status)
        }
    }

    /// Every page of a listing, following `@odata.nextLink` on the same host.
    func pages(_ first: URL, prefer: String? = nil) async throws(GraphError) -> [Data] {
        var next: URL? = first
        var pages: [Data] = []
        var total = 0
        for _ in 0..<Self.maxPages {
            guard let url = next else { return pages }
            let data = try await send("GET", url, prefer: prefer)
            total += data.count
            guard total <= Self.maxListing else { throw .tooLarge }
            pages.append(data)
            next = try GraphContacts.nextLink(data)
        }
        guard next == nil else { throw .tooLarge }
        return pages
    }

    /// https, or plain http to loopback; and on the base URL's scheme, host and port.
    private func check(_ url: URL) throws(GraphError) {
        let scheme = url.scheme?.lowercased()
        let host = url.host()?.lowercased() ?? ""
        guard scheme == base.scheme?.lowercased(), host == base.host()?.lowercased(), url.port == base.port else {
            throw .offHost
        }
        guard scheme == "https" || (scheme == "http" && Loopback.hosts.contains(host)) else {
            throw .plainRefused
        }
    }

    /// The status and at most `maxAnswer` bytes of body; redirects are not followed.
    private func fetch(_ request: URLRequest, limit: Int) async throws(GraphError) -> (Int, Data) {
        switch await CappedFetch.run(request, session: session, limit: limit) {
        case let .success(answer): return answer
        case .failure(.tooLarge): throw .tooLarge
        case .failure(.notHTTP): throw .malformed
        case .failure(.transport): throw .net
        }
    }
}
