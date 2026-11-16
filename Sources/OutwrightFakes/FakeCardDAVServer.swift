// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// An in-process CardDAV server on 127.0.0.1 for tests: plain HTTP/1.1, Basic auth for one
/// account, a principal at `/principals/jk/`, address books under `/books/`, cards at
/// `<book><uid>.vcf`. ETags and sync tokens are a counter. `/.well-known/carddav` redirects
/// to the principal (or where `redirectWellKnown` says) without asking for credentials.
public actor FakeCardDAVServer: FakeDAVHost {
    struct Card {
        var vcard: String
        var etag: String
        var modified: Int
    }

    struct Book {
        let name: String
        let readOnly: Bool
        var cards: [String: Card] = [:]
        var removed: [String: Int] = [:]
        var ctag = 0
    }

    enum Location {
        case principal, home, book(String), card(book: String, uid: String), none
    }

    static let principal = FakeDAVCore.principal
    static let home = "/books/"
    static let tokenPrefix = FakeDAVCore.tokenPrefix

    var core: FakeDAVCore
    let offersSyncCollection: Bool
    var books: [String: Book] = [:]
    var bookCount = 0
    var syncPageSize: Int?
    var syncWithoutETags = false
    var dropPutAnswer = false
    /// PUT and DELETE are answered with this status, `count` more times, without being carried out.
    var failingWrites: (status: Int, count: Int)?
    /// Book path → absolute hrefs of members on another origin, listed with the book's own.
    var foreignMembers: [String: [String]] = [:]
    // swiftlint:disable:next large_tuple
    public var requests: [(method: String, path: String, authorization: String?)] { core.requests }

    public init(user: String = "jk@example.org", password: String = "secret", offersSyncCollection: Bool = true) {
        core = FakeDAVCore(user: user, password: password, wellKnown: "/.well-known/carddav")
        self.offersSyncCollection = offersSyncCollection
    }

    public func start() async throws -> UInt16 {
        try await startServer()
    }

    public func stop() {
        stopServer()
    }

    // MARK: - State

    @discardableResult
    func store(_ vcard: String, uid: String, in path: String) -> String? {
        guard books[path] != nil else {
            return nil
        }
        let now = bump()
        let etag = "\"\(now)\""
        books[path]?.cards[uid] = Card(vcard: vcard, etag: etag, modified: now)
        books[path]?.removed[uid] = nil
        books[path]?.ctag = now
        return etag
    }

    func remove(uid: String, in path: String) {
        guard books[path]?.cards[uid] != nil else {
            return
        }
        let now = bump()
        books[path]?.cards[uid] = nil
        books[path]?.removed[uid] = now
        books[path]?.ctag = now
    }

    static func key(_ book: URL) -> String {
        FakeDAVCore.key(book)
    }

    static func cardPath(_ book: String, _ uid: String) -> String {
        FakeDAVCore.memberPath(book, uid, suffix: ".vcf")
    }

    func locate(_ path: String) -> Location {
        if path == "/" || path == Self.principal {
            return .principal
        }
        if path == Self.home {
            return .home
        }
        if books[path] != nil {
            return .book(path)
        }
        guard path.hasSuffix(".vcf"), let slash = path.lastIndex(of: "/") else {
            return .none
        }
        let book = String(path[...slash])
        let name = path[path.index(after: slash)...].dropLast(4)
        guard books[book] != nil, !name.isEmpty else {
            return .none
        }
        return .card(book: book, uid: name.removingPercentEncoding ?? String(name))
    }

    // MARK: - Serving

    func dropsAnswer(_ request: FakeHTTPRequest) -> Bool {
        guard request.method == "PUT", dropPutAnswer else {
            return false
        }
        dropPutAnswer = false
        return true
    }

    func preempt(_ request: FakeHTTPRequest) -> Data? {
        guard ["PUT", "DELETE"].contains(request.method), let failing = failingWrites, failing.count > 0 else {
            return nil
        }
        failingWrites = (failing.status, failing.count - 1)
        return FakeHTTP.response(failing.status)
    }

    func handle(_ request: FakeHTTPRequest) -> Data {
        switch request.method {
        case "PROPFIND": return propfind(request)
        case "REPORT": return report(request)
        case "GET": return get(request)
        case "PUT": return put(request)
        case "DELETE": return delete(request)
        default: return FakeHTTP.response(405)
        }
    }

    private func get(_ request: FakeHTTPRequest) -> Data {
        switch locate(request.path) {
        case let .card(book, uid):
            guard let card = books[book]?.cards[uid] else {
                return FakeHTTP.response(404)
            }
            return FakeHTTP.response(
                200, headers: [("Content-Type", "text/vcard; charset=utf-8"), ("ETag", card.etag)],
                body: Data(card.vcard.utf8))
        case .none:
            return FakeHTTP.response(404)
        default:
            return FakeHTTP.response(200, headers: [("Content-Type", "text/plain")], body: Data("CardDAV".utf8))
        }
    }

    private func put(_ request: FakeHTTPRequest) -> Data {
        guard case let .card(path, uid) = locate(request.path), let book = books[path] else {
            return FakeHTTP.response(409)
        }
        let existing = book.cards[uid]
        if let refusal = FakeDAVCore.putRefusal(request, existing: existing?.etag, readOnly: book.readOnly) {
            return refusal
        }
        let etag = store(fakeText(request.body), uid: uid, in: path) ?? ""
        return FakeHTTP.response(existing == nil ? 201 : 204, headers: [("ETag", etag)])
    }

    private func delete(_ request: FakeHTTPRequest) -> Data {
        guard case let .card(path, uid) = locate(request.path), let book = books[path],
            let card = book.cards[uid]
        else {
            return FakeHTTP.response(404)
        }
        if let refusal = FakeDAVCore.deleteRefusal(request, etag: card.etag, readOnly: book.readOnly) {
            return refusal
        }
        remove(uid: uid, in: path)
        return FakeHTTP.response(204)
    }
}

// MARK: - Test controls

extension FakeCardDAVServer {
    public func addBook(_ name: String, readOnly: Bool = false) -> URL {
        bookCount += 1
        let path = "\(Self.home)b\(bookCount)/"
        books[path] = Book(name: name, readOnly: readOnly, ctag: bump())
        return url(path)
    }

    public func putCard(_ vcard: String, uid: String, in book: URL) {
        store(vcard, uid: uid, in: Self.key(book))
    }

    public func removeCard(uid: String, in book: URL) {
        remove(uid: uid, in: Self.key(book))
    }

    public func removeBook(_ book: URL) {
        books[Self.key(book)] = nil
        core.revision += 1
    }

    /// uid → vCard text.
    public func cards(in book: URL) -> [String: String] {
        books[Self.key(book)]?.cards.mapValues(\.vcard) ?? [:]
    }

    /// Every sync token handed out so far stops being valid.
    public func forgetSyncTokens() {
        core.epoch += 1
    }

    public func redirectWellKnown(to target: String) {
        core.wellKnownTarget = target
    }

    /// `path` answers 301 to `target` (for an authorised request).
    public func redirect(_ path: String, to target: String) {
        core.redirects[path] = target
    }

    /// sync-collection answers at most `size` members, then a 507 for the collection and a
    /// token to go on from (RFC 6578 §3.6); nil answers everything at once.
    public func pageSyncCollection(_ size: Int?) {
        syncPageSize = size
    }

    /// `action` runs once as the next PUT arrives, before it is answered (the owner editing while
    /// a send is in flight, say).
    public func beforeNextPut(_ action: @escaping @Sendable () -> Void) {
        core.beforeNextPut = action
    }

    /// The next PUT is carried out but never answered: the connection closes instead.
    public func dropNextPutAnswer() {
        dropPutAnswer = true
    }

    /// The next `count` PUTs and DELETEs are answered with `status` and not carried out.
    public func failWrites(status: Int, count: Int) {
        failingWrites = (status, count)
    }

    /// sync-collection lists changed members without their ETags.
    public func omitSyncETags(_ omit: Bool) {
        syncWithoutETags = omit
    }

    /// Lists `href` (an absolute URL on another origin) as a member of `book` in PROPFIND,
    /// sync-collection and multiget answers.
    public func addForeignMember(_ href: String, in book: URL) {
        foreignMembers[Self.key(book), default: []].append(href)
    }
}
