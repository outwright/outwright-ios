// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// PROPFIND and REPORT for the fake CardDAV server, answered as multistatus XML.
extension FakeCardDAVServer {
    func propfind(_ request: FakeHTTPRequest) -> Data {
        let deep = request.headers["depth"] != "0"
        var responses: [String] = []
        switch locate(request.path) {
        case .principal:
            responses = [principalResponse(request.path)]
        case .home:
            responses = [Self.response(Self.home, "<d:resourcetype><d:collection/></d:resourcetype>")]
            if deep {
                responses += books.keys.sorted().map(bookResponse)
            }
        case let .book(path):
            responses = [bookResponse(path)]
            if deep, let book = books[path] {
                responses += book.cards.keys.sorted().compactMap { cardResponse(path, $0, withData: false) }
                responses += foreignResponses(path, withData: false)
            }
        case let .card(path, uid):
            guard let response = cardResponse(path, uid, withData: false) else {
                return FakeHTTP.response(404)
            }
            responses = [response]
        case .none:
            return FakeHTTP.response(404)
        }
        return Self.multistatus(responses)
    }

    func report(_ request: FakeHTTPRequest) -> Data {
        guard case let .book(path) = locate(request.path), let book = books[path] else {
            return FakeHTTP.response(404)
        }
        let body = fakeText(request.body)
        if body.contains("sync-collection") {
            return syncCollection(path, book, body)
        }
        guard body.contains("addressbook-multiget") else {
            return FakeHTTP.response(403)
        }
        let responses = body.matches(of: /<(?:\w+:)?href>([^<]*)<\//).map { match in
            let href = String(match.output.1)
            guard case let .card(cardBook, uid) = locate(href), cardBook == path,
                let response = cardResponse(path, uid, withData: true)
            else {
                return "<d:response><d:href>\(href)</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
            }
            return response
        }
        return Self.multistatus(responses + foreignResponses(path, withData: true))
    }

    private func syncCollection(_ path: String, _ book: Book, _ body: String) -> Data {
        guard offersSyncCollection else {
            return FakeHTTP.xml(403, "<d:error xmlns:d=\"DAV:\"><d:supported-report/></d:error>")
        }
        let token = body.firstMatch(of: /<(?:\w+:)?sync-token>([^<]*)<\//).map { String($0.output.1) } ?? ""
        var since = 0
        if !token.isEmpty {
            guard let issued = revision(of: token) else {
                return FakeHTTP.xml(403, "<d:error xmlns:d=\"DAV:\"><d:valid-sync-token/></d:error>")
            }
            since = issued
        }
        var members: [(revision: Int, xml: String)] = book.cards.filter { $0.value.modified > since }
            .compactMap { uid, card in
                cardResponse(path, uid, withData: false, withETag: !syncWithoutETags).map { (card.modified, $0) }
            }
        if !token.isEmpty {
            members += book.removed.filter { $0.value > since }.map { uid, removed in
                (removed, "<d:response><d:href>\(Self.cardPath(path, uid))</d:href>"
                    + "<d:status>HTTP/1.1 404 Not Found</d:status></d:response>")
            }
        }
        members.sort { $0.revision < $1.revision }
        guard let size = syncPageSize, members.count > size, size > 0 else {
            let all = members.map(\.xml) + foreignResponses(path, withData: false)
            return Self.multistatus(all, syncToken: syncToken)
        }
        let page = members.prefix(size)
        let truncated = "<d:response><d:href>\(path)</d:href>"
            + "<d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response>"
        let resume = "\(Self.tokenPrefix)\(core.epoch)-\(page.last?.revision ?? since)"
        return Self.multistatus(page.map(\.xml) + [truncated], syncToken: resume)
    }

    private func foreignResponses(_ path: String, withData: Bool) -> [String] {
        (foreignMembers[path] ?? []).map { href in
            let data = withData ? "<c:address-data>BEGIN:VCARD&#13;\nEND:VCARD&#13;\n</c:address-data>" : ""
            return Self.response(href, "<d:getetag>\"f\"</d:getetag><d:resourcetype/>\(data)")
        }
    }

    private func principalResponse(_ path: String) -> String {
        Self.response(
            path,
            "<d:current-user-principal><d:href>\(Self.principal)</d:href></d:current-user-principal>"
                + "<c:addressbook-home-set><d:href>\(Self.home)</d:href></c:addressbook-home-set>"
                + "<d:resourcetype><d:collection/><d:principal/></d:resourcetype>")
    }

    private func bookResponse(_ path: String) -> String {
        guard let book = books[path] else {
            return ""
        }
        var props = "<d:resourcetype><d:collection/><c:addressbook/></d:resourcetype>"
            + "<d:displayname>\(FakeHTTP.escape(book.name))</d:displayname>"
            + "<cs:getctag>\"\(book.ctag)\"</cs:getctag>"
        var reports = "<d:supported-report><d:report><c:addressbook-multiget/></d:report></d:supported-report>"
        if offersSyncCollection {
            props += "<d:sync-token>\(syncToken)</d:sync-token>"
            reports += "<d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report>"
        }
        props += "<d:supported-report-set>\(reports)</d:supported-report-set>"
        let privileges = book.readOnly ? ["read"] : ["read", "write", "write-content", "bind", "unbind"]
        props += "<d:current-user-privilege-set>"
            + privileges.map { "<d:privilege><d:\($0)/></d:privilege>" }.joined()
            + "</d:current-user-privilege-set>"
        return Self.response(path, props)
    }

    private func cardResponse(_ path: String, _ uid: String, withData: Bool, withETag: Bool = true) -> String? {
        guard let card = books[path]?.cards[uid] else {
            return nil
        }
        var props = withETag ? "<d:getetag>\(FakeHTTP.escape(card.etag))</d:getetag>" : ""
        props += "<d:getcontenttype>text/vcard</d:getcontenttype><d:resourcetype/>"
        if withData {
            props += "<c:address-data>\(FakeHTTP.escape(card.vcard))</c:address-data>"
        }
        return Self.response(Self.cardPath(path, uid), props)
    }

    private static func response(_ href: String, _ props: String) -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private static func multistatus(_ responses: [String], syncToken: String? = nil) -> Data {
        let token = syncToken.map { "<d:sync-token>\($0)</d:sync-token>" } ?? ""
        return FakeHTTP.xml(
            207,
            "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:carddav\" "
                + "xmlns:cs=\"http://calendarserver.org/ns/\">\(responses.joined())\(token)</d:multistatus>")
    }
}
