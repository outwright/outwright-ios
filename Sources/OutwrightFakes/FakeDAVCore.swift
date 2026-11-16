// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What the CardDAV and CalDAV fakes share: the listener and its connections, the Basic-auth
/// gate, redirects, the request log, and the revision and sync-token bookkeeping.
struct FakeDAVCore {
    static let principal = "/principals/jk/"
    static let tokenPrefix = "http://fake.example/sync/"

    let user: String
    let password: String
    /// The path that redirects, without credentials, to the principal (`/.well-known/caldav`).
    let wellKnown: String
    var listener: FakeListener?
    var open: [FakeConnection] = []
    var port: UInt16 = 0
    var revision = 0
    var epoch = 0
    var wellKnownTarget: String?
    /// Path → where it redirects, after asking for credentials like any other path.
    var redirects: [String: String] = [:]
    /// Run once as the next authorised PUT arrives, before it is answered: something that happens
    /// while a send is in flight.
    var beforeNextPut: (@Sendable () -> Void)?
    // swiftlint:disable:next large_tuple
    var requests: [(method: String, path: String, authorization: String?)] = []

    init(user: String, password: String, wellKnown: String) {
        self.user = user
        self.password = password
        self.wellKnown = wellKnown
    }

    mutating func bump() -> Int {
        revision += 1
        return revision
    }

    var syncToken: String { "\(Self.tokenPrefix)\(epoch)-\(revision)" }

    /// The revision a token was handed out at, or nil when it is not (or no longer) valid.
    func revision(of token: String) -> Int? {
        guard token.hasPrefix(Self.tokenPrefix) else {
            return nil
        }
        let parts = token.dropFirst(Self.tokenPrefix.count).split(separator: "-")
        guard parts.count == 2, Int(parts[0]) == epoch, let issued = Int(parts[1]), issued <= revision else {
            return nil
        }
        return issued
    }

    func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        return components.url ?? URL(filePath: path)
    }

    /// A collection URL's path with a trailing slash.
    static func key(_ collection: URL) -> String {
        let path = collection.path(percentEncoded: true)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// `<collection><uid><suffix>` with the uid percent-encoded.
    static func memberPath(_ collection: String, _ uid: String, suffix: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@"))
        return collection + (uid.addingPercentEncoding(withAllowedCharacters: allowed) ?? uid) + suffix
    }

    /// The refusal for a PUT, or nil when it may go ahead: a read-only collection, a stale
    /// `If-Match`, or `If-None-Match: *` on a resource that exists.
    static func putRefusal(_ request: FakeHTTPRequest, existing etag: String?, readOnly: Bool) -> Data? {
        guard !readOnly else {
            return FakeHTTP.response(403)
        }
        if let match = request.headers["if-match"], match != etag {
            return FakeHTTP.response(412)
        }
        if request.headers["if-none-match"] == "*", etag != nil {
            return FakeHTTP.response(412)
        }
        return nil
    }

    /// The refusal for a DELETE of a resource that has `etag`, or nil.
    static func deleteRefusal(_ request: FakeHTTPRequest, etag: String, readOnly: Bool) -> Data? {
        guard !readOnly else {
            return FakeHTTP.response(403)
        }
        if let match = request.headers["if-match"], match != etag {
            return FakeHTTP.response(412)
        }
        return nil
    }
}

/// An actor that serves WebDAV from a `FakeDAVCore`; it answers only what is resource-shaped.
protocol FakeDAVHost: Actor {
    var core: FakeDAVCore { get set }
    /// The answer to an authorised, unredirected request.
    func handle(_ request: FakeHTTPRequest) -> Data
    /// An answer given before redirects, once the user is known (a failing write, say).
    func preempt(_ request: FakeHTTPRequest) -> Data?
    /// Whether the answer is to be dropped, closing the connection.
    func dropsAnswer(_ request: FakeHTTPRequest) -> Bool
}

extension FakeDAVHost {
    func preempt(_ request: FakeHTTPRequest) -> Data? { nil }
    func dropsAnswer(_ request: FakeHTTPRequest) -> Bool { false }

    func bump() -> Int { core.bump() }
    var syncToken: String { core.syncToken }
    func revision(of token: String) -> Int? { core.revision(of: token) }
    func url(_ path: String) -> URL { core.url(path) }

    func startServer() async throws -> UInt16 {
        let listener = FakeListener { [weak self] connection in
            await self?.serve(connection)
        }
        core.listener = listener
        core.port = try await listener.start()
        return core.port
    }

    func stopServer() {
        core.listener?.stop()
        for connection in core.open {
            connection.close()
        }
        core.open = []
    }

    private func serve(_ connection: FakeConnection) async {
        core.open.append(connection)
        while let request = await FakeHTTP.read(connection) {
            let answer = respond(request)
            if dropsAnswer(request) {
                break
            }
            connection.send(answer)
        }
        connection.close()
        core.open.removeAll { $0 === connection }
    }

    private func respond(_ request: FakeHTTPRequest) -> Data {
        core.requests.append((request.method, request.path, request.headers["authorization"]))
        if request.path == core.wellKnown {
            return FakeHTTP.response(301, headers: [("Location", core.wellKnownTarget ?? FakeDAVCore.principal)])
        }
        let expected = "Basic " + Data("\(core.user):\(core.password)".utf8).base64EncodedString()
        guard request.headers["authorization"] == expected else {
            return FakeHTTP.response(401, headers: [("WWW-Authenticate", "Basic realm=\"fake\"")])
        }
        if request.method == "PUT", let action = core.beforeNextPut {
            core.beforeNextPut = nil
            action()
        }
        if let answer = preempt(request) {
            return answer
        }
        if let target = core.redirects[request.path] {
            return FakeHTTP.response(301, headers: [("Location", target)])
        }
        return handle(request)
    }
}
