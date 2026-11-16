// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// An address book collection on the server.
public struct RemoteAddressBook: Sendable, Equatable {
    public let href: URL
    public let name: String
    /// The CalendarServer `getctag`: changes whenever any card in the book changes.
    public let ctag: String?
    public let syncToken: String?
    public let offersSyncCollection: Bool
    public let isReadOnly: Bool
}

/// One vCard resource as the server holds it.
public struct RemoteCard: Sendable {
    public let href: URL
    public let etag: String
    public let data: Data
}

/// What changed in a collection since a sync token.
public struct CollectionChanges: Sendable {
    public let changed: [(href: URL, etag: String)]
    public let removed: [URL]
    /// The token to ask with next time.
    public let token: String?
}

/// CardDAV (RFC 6352) against one account's server: discovery, sync-collection (RFC 6578),
/// ETags, multiget, and writes with preconditions. Credentials go only to `trustedHosts`.
public actor CardDAVClient {
    private let context: URL
    private let resources: DAVResources

    public init(context: URL, credentials: DAVCredentials, trustedHosts: Set<String>, session: URLSession = .shared) {
        self.context = context
        resources = DAVResources(
            http: HTTPClient(credentials: credentials, trustedHosts: trustedHosts, session: session))
    }

    /// Every address book: current-user-principal, then addressbook-home-set, then the home's
    /// members.
    public func addressBooks() async throws(DAVError) -> [RemoteAddressBook] {
        let home = try await resources.home(context, homeSet: .cardDAV("addressbook-home-set"), prefix: "c")
        let props = """
            <d:resourcetype/><d:displayname/><cs:getctag/><d:sync-token/><d:supported-report-set/>\
            <d:current-user-privilege-set/>
            """
        let (members, base) = try await resources.propfind(home, depth: 1, props)
        var books: [RemoteAddressBook] = []
        for response in members.responses where books.count < DAVLimits.addressBooksPerAccount {
            if let book = Self.book(response, base) {
                books.append(book)
            }
        }
        return books
    }

    /// Changes since `token` (nil: everything) by REPORT sync-collection, sync-level 1. A
    /// truncated answer (507 on the collection) is followed with its token until complete. A
    /// changed member the server gave no ETag for comes with an empty `etag`.
    public func changes(_ book: URL, since token: String?) async throws(DAVError) -> CollectionChanges {
        try await resources.changes(book, since: token, limit: DAVLimits.cardsPerAddressBook)
    }

    /// Every card's ETag, by PROPFIND Depth 1.
    public func etags(_ book: URL) async throws(DAVError) -> [URL: String] {
        try await resources.etags(book, limit: DAVLimits.cardsPerAddressBook)
    }

    /// The cards at `hrefs`, by addressbook-multiget in batches of 100. Cards the server does
    /// not have, or past the vCard size cap, are left out.
    public func cards(_ book: URL, hrefs: [URL]) async throws(DAVError) -> [RemoteCard] {
        let kind = DAVResources.Multiget(
            root: .cardDAV("addressbook-multiget"), data: .cardDAV("address-data"),
            maxBytes: DAVLimits.vCardBytes, prefix: "c")
        let found = try await resources.multiget(book, hrefs: hrefs, kind, limit: DAVLimits.cardsPerAddressBook).found
        return found.map { RemoteCard(href: $0.href, etag: $0.etag, data: $0.data) }
    }

    /// Writes a card. A nil `ifMatch` creates it (`If-None-Match: *`). Returns the new ETag
    /// when the server gives one.
    public func put(_ data: Data, at href: URL, ifMatch etag: String?) async throws(DAVError) -> String? {
        try await resources.put(data, at: href, ifMatch: etag, contentType: "text/vcard; charset=utf-8").etag
    }

    /// Deletes a card if it still has `etag`. A card already gone counts as deleted.
    public func delete(_ href: URL, ifMatch etag: String) async throws(DAVError) {
        try await resources.delete(href, ifMatch: etag)
    }

    private static func book(_ response: Multistatus.Response, _ base: URL) -> RemoteAddressBook? {
        guard let types = response.property(.dav("resourcetype")),
            types.descendants.contains(.cardDAV("addressbook")),
            let href = DAVResources.resolve(response.href, base), DAVResources.sameOrigin(href, base)
        else {
            return nil
        }
        let reports = response.property(.dav("supported-report-set"))?.descendants ?? []
        let name = response.property(.dav("displayname")).flatMap { DAVResources.nonEmpty($0.text) }
        return RemoteAddressBook(
            href: href,
            name: name ?? (href.lastPathComponent.removingPercentEncoding ?? href.lastPathComponent),
            ctag: response.property(QName(namespace: DAVNamespace.calendarServer, name: "getctag"))
                .flatMap { DAVResources.nonEmpty($0.text) },
            syncToken: response.property(.dav("sync-token")).flatMap { DAVResources.nonEmpty($0.text) },
            offersSyncCollection: reports.contains(.dav("sync-collection")),
            isReadOnly: DAVResources.isReadOnly(response.property(.dav("current-user-privilege-set"))))
    }
}

/// Finds where a CardDAV server keeps its context (RFC 6764 §5).
public enum WellKnown {
    /// GETs `url` without credentials, following up to five redirects, and returns the URL
    /// that answered 401 or 207 (a DAV server asking who it is talking to), or nil. A plain
    /// 2xx does not count: a website answers every path so.
    public static func probe(_ url: URL, session: URLSession = .shared) async -> URL? {
        var http = HTTPClient(credentials: nil, trustedHosts: nil, session: session)
        http.bodyLimit = 0
        guard let reply = try? await http.send("GET", url) else {
            return nil
        }
        return [207, 401].contains(reply.status) ? reply.url : nil
    }
}
