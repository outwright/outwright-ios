// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

extension DAVNamespace {
    static let calDAV = "urn:ietf:params:xml:ns:caldav"
    static let appleICal = "http://apple.com/ns/ical/"
}

/// One resource (a vCard or an iCalendar) as the server holds it.
public struct RemoteResource: Sendable {
    public let href: URL
    public let etag: String
    public let data: Data
    /// The CalDAV `Schedule-Tag` (RFC 6638) of an object the server's own scheduling keeps; nil for
    /// none (and always for a vCard).
    public let scheduleTag: String?
}

/// What the server answered to a write: the new ETag and, for an object the server schedules, its
/// `Schedule-Tag`; each nil when not given.
public struct PutAnswer: Sendable, Equatable {
    public let etag: String?
    public let scheduleTag: String?

    public init(etag: String?, scheduleTag: String?) {
        self.etag = etag
        self.scheduleTag = scheduleTag
    }
}

/// What a multiget handed over, and the members it left out because they are past the size cap
/// (as opposed to members the server does not have).
public struct FetchedResources: Sendable {
    public let found: [RemoteResource]
    public let oversized: [URL]
}

/// The collection calls CardDAV and CalDAV share: sync-collection with paging, ETags,
/// multiget in parts, writes with preconditions. Everything the server names is checked
/// against the collection's origin.
struct DAVResources: Sendable {
    let http: HTTPClient
    static let multigetBatch = 100

    /// Changes since `token` (nil: everything) by REPORT sync-collection, sync-level 1. A
    /// truncated answer (507 on the collection) is followed with its token until complete. A
    /// changed member the server gave no ETag for comes with an empty `etag`.
    func changes(_ collection: URL, since token: String?, limit: Int) async throws(DAVError) -> CollectionChanges {
        var token = token
        var order: [URL] = []
        var latest: [URL: String?] = [:]
        for _ in 0..<DAVLimits.syncRounds {
            let page = try await syncPage(collection, since: token)
            for (href, etag) in page.members {
                let isNew = latest[href] == nil
                latest[href] = .some(etag)
                order += isNew ? [href] : []
            }
            guard latest.count <= limit else {
                throw .tooLarge
            }
            guard page.truncated else {
                let changed = order.compactMap { href in latest[href].flatMap { $0 }.map { (href: href, etag: $0) } }
                let removed = order.filter { latest[$0] == .some(nil) }
                return CollectionChanges(changed: changed, removed: removed, token: page.token)
            }
            guard let next = page.token, next != token else {
                throw .malformed
            }
            token = next
        }
        throw .tooLarge
    }

    /// One sync-collection answer: members (nil ETag: removed), its token, and whether the
    /// server cut it short.
    private struct SyncPage {
        let members: [(URL, String?)]
        let token: String?
        let truncated: Bool
    }

    private func syncPage(_ collection: URL, since token: String?) async throws(DAVError) -> SyncPage {
        let tokenXML = token.map { "<d:sync-token>\(Self.escape($0))</d:sync-token>" } ?? "<d:sync-token/>"
        let body = """
            <?xml version="1.0" encoding="utf-8"?><d:sync-collection xmlns:d="DAV:">\(tokenXML)\
            <d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>
            """
        let reply = try await http.send(
            "REPORT", collection, headers: Self.xmlHeaders(depth: 0), body: Data(body.utf8))
        if reply.status == 403 || reply.status == 409, reply.body.range(of: Data("valid-sync-token".utf8)) != nil {
            throw .tokenInvalid
        }
        let status = try Self.multistatus(reply)
        var members: [(URL, String?)] = []
        var truncated = false
        for response in status.responses {
            guard let href = Self.resolve(response.href, reply.url), Self.sameOrigin(href, collection) else {
                continue
            }
            if Self.same(href, collection) {
                truncated = truncated || response.status == 507
            } else if response.status == 404 {
                members.append((href, nil))
            } else if response.status.map({ (200..<300).contains($0) }) ?? true {
                members.append((href, response.property(.dav("getetag"))?.text ?? ""))
            }
        }
        return SyncPage(members: members, token: status.syncToken.flatMap(Self.nonEmpty), truncated: truncated)
    }

    /// Every member's ETag, by PROPFIND Depth 1.
    func etags(_ collection: URL, limit: Int) async throws(DAVError) -> [URL: String] {
        let (status, base) = try await propfind(collection, depth: 1, "<d:getetag/><d:resourcetype/>")
        return Self.etags(status, base, collection, limit: limit)
    }

    /// The members with an ETag in a multistatus (collections and foreign origins left out).
    static func etags(_ status: Multistatus, _ base: URL, _ collection: URL, limit: Int) -> [URL: String] {
        var etags: [URL: String] = [:]
        for response in status.responses where etags.count < limit {
            let types = response.property(.dav("resourcetype"))?.descendants ?? []
            let isCollection = types.contains(.dav("collection"))
            guard !isCollection, let href = resolve(response.href, base), sameOrigin(href, collection),
                !same(href, collection),
                let etag = response.property(.dav("getetag"))?.text, !etag.isEmpty
            else {
                continue
            }
            etags[href] = etag
        }
        return etags
    }

    /// What a multiget asks for: the report's root element, the element carrying the data, the
    /// largest resource kept, and the schedule-tag property where there is one (CalDAV's).
    struct Multiget {
        let root: QName
        let data: QName
        let maxBytes: Int
        let prefix: String
        var scheduleTag: QName?
    }

    /// Writes a resource. A nil `ifMatch` creates it (`If-None-Match: *`). Returns the new ETag
    /// and `Schedule-Tag` the server gives.
    func put(
        _ data: Data, at href: URL, ifMatch etag: String?, contentType: String
    ) async throws(DAVError) -> PutAnswer {
        var headers = ["Content-Type": contentType]
        if let etag {
            headers["If-Match"] = etag
        } else {
            headers["If-None-Match"] = "*"
        }
        let reply = try await http.send("PUT", href, headers: headers, body: data)
        try Self.check(reply)
        return PutAnswer(
            etag: reply.header("etag").flatMap(Self.nonEmpty),
            scheduleTag: reply.header("schedule-tag").flatMap(Self.nonEmpty))
    }

    /// Deletes a resource if it still has `etag`. One already gone counts as deleted.
    func delete(_ href: URL, ifMatch etag: String, headers: [String: String] = [:]) async throws(DAVError) {
        let reply = try await http.send("DELETE", href, headers: headers.merging(["If-Match": etag]) { _, new in new })
        if reply.status == 404 {
            return
        }
        try Self.check(reply)
    }

    // MARK: - Requests

    /// The compliance classes in the DAV header of OPTIONS on `url` (RFC 4918 › 10.1), lowercased.
    func davClasses(_ url: URL) async throws(DAVError) -> Set<String> {
        let reply = try await http.send("OPTIONS", url)
        try Self.check(reply)
        let header = reply.header("dav") ?? ""
        return Set(
            header.split(separator: ",", maxSplits: DAVLimits.davClasses).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            })
    }

    func propfind(_ url: URL, depth: Int, _ props: String) async throws(DAVError) -> (Multistatus, URL) {
        let body = """
            <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="\(DAVNamespace.cardDAV)" \
            xmlns:cal="\(DAVNamespace.calDAV)" xmlns:ic="\(DAVNamespace.appleICal)" \
            xmlns:cs="\(DAVNamespace.calendarServer)"><d:prop>\(props)</d:prop></d:propfind>
            """
        let reply = try await http.send("PROPFIND", url, headers: Self.xmlHeaders(depth: depth), body: Data(body.utf8))
        return (try Self.multistatus(reply), reply.url)
    }

    /// The home of the account's collections: principal, then the home-set property
    /// (`prefix:name`, `c` or `cal`).
    func home(_ context: URL, homeSet: QName, prefix: String) async throws(DAVError) -> URL {
        let (first, firstBase) = try await propfind(context, depth: 0, "<d:current-user-principal/>")
        let principal = Self.firstHref(first, .dav("current-user-principal"), firstBase) ?? firstBase
        let (second, secondBase) = try await propfind(principal, depth: 0, "<\(prefix):\(homeSet.name)/>")
        return Self.firstHref(second, homeSet, secondBase) ?? secondBase
    }

    // MARK: - Reading answers

    static func xmlHeaders(depth: Int) -> [String: String] {
        ["Depth": "\(depth)", "Content-Type": "application/xml; charset=utf-8"]
    }

    static func check(_ reply: HTTPReply) throws(DAVError) {
        if reply.status == 403 || reply.status == 412,
            reply.body.range(of: Data("allowed-attendee-scheduling-object-change".utf8)) != nil {
            throw .attendeeChangeRefused
        }
        switch reply.status {
        case 200..<300: return
        case 401: throw .unauthorized
        case 404: throw .notFound
        case 412: throw .preconditionFailed
        default: throw .status(reply.status)
        }
    }

    static func multistatus(_ reply: HTTPReply) throws(DAVError) -> Multistatus {
        try check(reply)
        guard reply.status == 207 else {
            throw .status(reply.status)
        }
        return try Multistatus.parse(reply.body)
    }

    /// Read-only when the server lists the user's privileges and none of them lets it write.
    static func isReadOnly(_ privileges: Multistatus.Property?) -> Bool {
        guard let privileges else {
            return false
        }
        let writes: [QName] = [.dav("write"), .dav("write-content"), .dav("all")]
        return !writes.contains { privileges.descendants.contains($0) }
    }

    static func firstHref(_ status: Multistatus, _ name: QName, _ base: URL) -> URL? {
        for response in status.responses {
            if let href = response.property(name)?.hrefs.first, let url = resolve(href, base) {
                return url
            }
        }
        return nil
    }

    static func resolve(_ href: String, _ base: URL) -> URL? {
        guard !href.isEmpty else {
            return nil
        }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    /// Same scheme, host and port: a server-named href elsewhere is never followed.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host() else {
                return nil
            }
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return "\(scheme)://\(Hosts.normalize(host)):\(port)"
        }
        guard let left = origin(lhs) else {
            return false
        }
        return left == origin(rhs)
    }

    /// The same resource, whether or not one of them ends in a slash.
    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        func key(_ url: URL) -> String {
            var text = url.absoluteString
            while text.hasSuffix("/") {
                text.removeLast()
            }
            return text
        }
        return key(lhs) == key(rhs)
    }

    static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension DAVResources {
    /// The members at `hrefs`, by multiget in batches of 100. Members the server does not have,
    /// or past the size cap, are left out.
    func multiget(
        _ collection: URL, hrefs: [URL], _ kind: Multiget, limit: Int
    ) async throws(DAVError) -> FetchedResources {
        let wanted = Array(hrefs.prefix(limit))
        var found: [RemoteResource] = []
        var oversized: [URL] = []
        for start in stride(from: 0, to: wanted.count, by: Self.multigetBatch) {
            let batch = wanted.dropFirst(start).prefix(Self.multigetBatch)
            let part = try await multigetInParts(collection, batch, kind)
            found += part.found
            oversized += part.oversized
        }
        return FetchedResources(found: found, oversized: oversized)
    }

    /// A batch whose answer is past a cap is asked for again in halves; a single member whose
    /// answer is still past it is left out like any member over the size cap. At most 2n requests.
    private func multigetInParts(
        _ collection: URL, _ hrefs: ArraySlice<URL>, _ kind: Multiget
    ) async throws(DAVError) -> FetchedResources {
        var parts = [hrefs]
        var found: [RemoteResource] = []
        var oversized: [URL] = []
        while let part = parts.popLast() {
            do {
                let batch = try await multigetBatch(collection, part, kind)
                found += batch.found
                oversized += batch.oversized
            } catch .tooLarge {
                guard part.count > 1 else {
                    oversized += part
                    continue
                }
                let middle = part.startIndex + part.count / 2
                parts.append(part[middle...])
                parts.append(part[..<middle])
            }
        }
        return FetchedResources(found: found, oversized: oversized)
    }

    private func multigetBatch(
        _ collection: URL, _ hrefs: ArraySlice<URL>, _ kind: Multiget
    ) async throws(DAVError) -> FetchedResources {
        let list = hrefs.map { "<d:href>\(Self.escape($0.path(percentEncoded: true)))</d:href>" }.joined()
        let tag = kind.scheduleTag.map { "<\(kind.prefix):\($0.name)/>" } ?? ""
        let body = """
            <?xml version="1.0" encoding="utf-8"?><\(kind.prefix):\(kind.root.name) xmlns:d="DAV:" \
            xmlns:\(kind.prefix)="\(kind.root.namespace)"><d:prop><d:getetag/><\(kind.prefix):\(kind.data.name)/>\
            \(tag)</d:prop>\(list)</\(kind.prefix):\(kind.root.name)>
            """
        let headers = ["Content-Type": "application/xml; charset=utf-8"]
        let reply = try await http.send("REPORT", collection, headers: headers, body: Data(body.utf8))
        let status = try Self.multistatus(reply)
        var found: [RemoteResource] = []
        var oversized: [URL] = []
        for response in status.responses {
            guard let href = Self.resolve(response.href, reply.url), Self.sameOrigin(href, collection),
                let etag = response.property(.dav("getetag"))?.text, !etag.isEmpty,
                let text = response.property(kind.data)?.raw
            else {
                continue
            }
            guard text.utf8.count <= kind.maxBytes else {
                oversized.append(href)
                continue
            }
            let tag = kind.scheduleTag.flatMap { response.property($0)?.text }.flatMap(Self.nonEmpty)
            found.append(RemoteResource(href: href, etag: etag, data: Data(text.utf8), scheduleTag: tag))
        }
        return FetchedResources(found: found, oversized: oversized)
    }
}
