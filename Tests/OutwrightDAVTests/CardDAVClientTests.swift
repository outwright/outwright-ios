// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightDAV

@Suite struct CardDAVClientTests {
    let session = URLSession(configuration: .ephemeral)

    private func start(sync: Bool = true) async throws -> (FakeCardDAVServer, URL) {
        let server = FakeCardDAVServer(offersSyncCollection: sync)
        let port = try await server.start()
        return (server, try #require(URL(string: "http://127.0.0.1:\(port)/")))
    }

    private func client(_ context: URL, password: String = "secret") -> CardDAVClient {
        CardDAVClient(
            context: context, credentials: DAVCredentials(user: "jk@example.org", password: password),
            trustedHosts: ["127.0.0.1"], session: session)
    }

    private static func vcard(_ uid: String, _ name: String) -> String {
        "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:\(uid)\r\nFN:\(name)\r\nEND:VCARD\r\n"
    }

    @Test func findsEveryAddressBook() async throws {
        let (server, context) = try await start()
        _ = await server.addBook("Work")
        _ = await server.addBook("Shared", readOnly: true)
        let books = try await client(context).addressBooks()
        await server.stop()
        #expect(books.map(\.name).sorted() == ["Shared", "Work"])
        #expect(books.first { $0.name == "Shared" }?.isReadOnly == true)
        #expect(books.first { $0.name == "Work" }?.isReadOnly == false)
        #expect(books.allSatisfy { $0.offersSyncCollection })
        #expect(books.allSatisfy { $0.ctag != nil && $0.syncToken != nil })
    }

    @Test func booksWithoutSyncCollectionSaySo() async throws {
        let (server, context) = try await start(sync: false)
        _ = await server.addBook("Work")
        let books = try await client(context).addressBooks()
        await server.stop()
        #expect(books.count == 1)
        #expect(books.first?.offersSyncCollection == false)
        #expect(books.first?.ctag != nil)
    }

    @Test func followsTrustedRedirectFromWellKnown() async throws {
        let (server, context) = try await start()
        _ = await server.addBook("Work")
        let books = try await client(context.appending(path: ".well-known/carddav")).addressBooks()
        await server.stop()
        #expect(books.map(\.name) == ["Work"])
    }

    @Test func syncCollectionReportsChangesAndRemovals() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        for uid in ["a", "b", "c"] { await server.putCard(Self.vcard(uid, uid), uid: uid, in: book) }
        let dav = client(context)
        let first = try await dav.changes(book, since: nil)
        #expect(Set(first.changed.map(\.href.lastPathComponent)) == ["a.vcf", "b.vcf", "c.vcf"])
        #expect(first.removed.isEmpty)
        let token = try #require(first.token)
        await server.putCard(Self.vcard("b", "Bea"), uid: "b", in: book)
        await server.removeCard(uid: "c", in: book)
        let second = try await dav.changes(book, since: token)
        await server.stop()
        #expect(second.changed.map(\.href.lastPathComponent) == ["b.vcf"])
        #expect(second.removed.map(\.lastPathComponent) == ["c.vcf"])
        #expect(second.token != nil && second.token != token)
    }

    @Test func forgottenTokenIsReported() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        await server.putCard(Self.vcard("a", "A"), uid: "a", in: book)
        let dav = client(context)
        let token = try #require(try await dav.changes(book, since: nil).token)
        await server.forgetSyncTokens()
        await #expect(throws: DAVError.tokenInvalid) { try await dav.changes(book, since: token) }
        await server.stop()
    }

    @Test func etagsAndMultigetReadEveryCard() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        for index in 0..<250 { await server.putCard(Self.vcard("u\(index)", "N\(index)"), uid: "u\(index)", in: book) }
        let dav = client(context)
        let etags = try await dav.etags(book)
        #expect(etags.count == 250)
        let cards = try await dav.cards(book, hrefs: Array(etags.keys))
        let reports = await server.requests.filter { $0.method == "REPORT" }.count
        await server.stop()
        #expect(cards.count == 250)
        #expect(reports == 3)
        for card in cards {
            #expect(etags[card.href] == card.etag)
            let uid = card.href.deletingPathExtension().lastPathComponent
            #expect(String(decoding: card.data, as: UTF8.self).contains("UID:\(uid)\r\n"))
        }
    }

    @Test func multigetKeepsCardBytesExactly() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        let text = Self.vcard("a", "A") + "\r\n  "
        await server.putCard(text, uid: "a", in: book)
        let cards = try await client(context).cards(book, hrefs: [book.appending(path: "a.vcf")])
        await server.stop()
        #expect(cards.map(\.data) == [Data(text.utf8)])
    }

    @Test func truncatedSyncCollectionIsFollowedToTheEnd() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        for index in 0..<25 { await server.putCard(Self.vcard("u\(index)", "N"), uid: "u\(index)", in: book) }
        await server.pageSyncCollection(10)
        let dav = client(context)
        let first = try await dav.changes(book, since: nil)
        #expect(Set(first.changed.map(\.href.lastPathComponent)).count == 25)
        let token = try #require(first.token)
        for index in 0..<12 { await server.putCard(Self.vcard("u\(index)", "M"), uid: "u\(index)", in: book) }
        for index in 20..<23 { await server.removeCard(uid: "u\(index)", in: book) }
        let second = try await dav.changes(book, since: token)
        let reports = await server.requests.filter { $0.method == "REPORT" }.count
        await server.stop()
        #expect(Set(second.changed.map(\.href.lastPathComponent)) == Set((0..<12).map { "u\($0).vcf" }))
        #expect(Set(second.removed.map(\.lastPathComponent)) == Set((20..<23).map { "u\($0).vcf" }))
        #expect(reports == 5)
    }

    @Test func syncMemberWithoutETagIsStillReported() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        for uid in ["a", "b"] { await server.putCard(Self.vcard(uid, uid), uid: uid, in: book) }
        await server.omitSyncETags(true)
        let changes = try await client(context).changes(book, since: nil)
        await server.stop()
        #expect(Set(changes.changed.map(\.href.lastPathComponent)) == ["a.vcf", "b.vcf"])
        #expect(changes.changed.allSatisfy { $0.etag.isEmpty })
    }

    @Test func hrefsOutsideTheBooksOriginAreIgnored() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        await server.putCard(Self.vcard("a", "A"), uid: "a", in: book)
        let port = try #require(context.port)
        for href in ["https://evil.example.net/books/b1/x.vcf", "http://127.0.0.1:\(port &+ 1)/books/b1/y.vcf"] {
            await server.addForeignMember(href, in: book)
        }
        let dav = client(context)
        let etags = try await dav.etags(book)
        let changes = try await dav.changes(book, since: nil)
        let cards = try await dav.cards(book, hrefs: [book.appending(path: "a.vcf")])
        await server.stop()
        #expect(etags.keys.map(\.lastPathComponent) == ["a.vcf"])
        #expect(changes.changed.map(\.href.lastPathComponent) == ["a.vcf"])
        #expect(cards.map(\.href.lastPathComponent) == ["a.vcf"])
    }

    @Test func alreadyCancelledCallReturns() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        let dav = client(context)
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let call = Task {
                    while !Task.isCancelled { await Task.yield() }
                    _ = try? await dav.etags(book)
                }
                call.cancel()
                await call.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await server.stop()
        #expect(finished)
    }

    @Test func putCreatesAndUpdatesWithPreconditions() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        let dav = client(context)
        let href = book.appending(path: "new.vcf")
        let created = try await dav.put(Data(Self.vcard("new", "New").utf8), at: href, ifMatch: nil)
        let etag = try #require(created)
        #expect(await server.cards(in: book)["new"] == Self.vcard("new", "New"))
        await #expect(throws: DAVError.preconditionFailed) {
            try await dav.put(Data(Self.vcard("new", "Other").utf8), at: href, ifMatch: nil)
        }
        await #expect(throws: DAVError.preconditionFailed) {
            try await dav.put(Data(Self.vcard("new", "Stale").utf8), at: href, ifMatch: "\"stale\"")
        }
        #expect(await server.cards(in: book)["new"] == Self.vcard("new", "New"))
        let updated = try await dav.put(Data(Self.vcard("new", "Newer").utf8), at: href, ifMatch: etag)
        #expect(updated != nil && updated != etag)
        #expect(await server.cards(in: book)["new"] == Self.vcard("new", "Newer"))
        await server.stop()
    }

    @Test func deleteHonoursETagAndCountsMissingAsDone() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        await server.putCard(Self.vcard("a", "A"), uid: "a", in: book)
        let dav = client(context)
        let href = book.appending(path: "a.vcf")
        let etag = try #require(try await dav.etags(book)[href])
        await #expect(throws: DAVError.preconditionFailed) { try await dav.delete(href, ifMatch: "\"stale\"") }
        #expect(await server.cards(in: book)["a"] != nil)
        try await dav.delete(href, ifMatch: etag)
        #expect(await server.cards(in: book)["a"] == nil)
        try await dav.delete(href, ifMatch: etag)
        await server.stop()
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let (server, context) = try await start()
        _ = await server.addBook("Work")
        await #expect(throws: DAVError.unauthorized) { try await client(context, password: "wrong").addressBooks() }
        let requests = await server.requests
        await server.stop()
        #expect(requests.count == 1)
    }

    @Test func cardTooLargeForAnyAnswerIsSkippedAndTheRestRead() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        let huge = "BEGIN:VCARD\r\nNOTE:" + String(repeating: "x", count: DAVLimits.responseBytes) + "\r\nEND:VCARD\r\n"
        await server.putCard(huge, uid: "big", in: book)
        for uid in ["a", "b", "c"] {
            await server.putCard(Self.vcard(uid, uid.uppercased()), uid: uid, in: book)
        }
        let hrefs = ["a", "big", "b", "c"].map { book.appending(path: "\($0).vcf") }
        let cards = try await client(context).cards(book, hrefs: hrefs)
        await server.stop()
        #expect(cards.map(\.href.lastPathComponent).sorted() == ["a.vcf", "b.vcf", "c.vcf"])
    }

    @Test func batchPastTheAnswerCapIsFetchedInParts() async throws {
        let (server, context) = try await start()
        let book = await server.addBook("Work")
        // 24 cards of 750 KB: one answer would pass 16 MiB, each card fits under the vCard cap.
        let uids = (0..<24).map { "p\($0)" }
        for uid in uids {
            let text = "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:\(uid)\r\nNOTE:"
                + String(repeating: "y", count: 750_000) + "\r\nEND:VCARD\r\n"
            await server.putCard(text, uid: uid, in: book)
        }
        let cards = try await client(context).cards(book, hrefs: uids.map { book.appending(path: "\($0).vcf") })
        await server.stop()
        #expect(Set(cards.map(\.href.lastPathComponent)) == Set(uids.map { "\($0).vcf" }))
    }

    @Test func plainHTTPRefusedForRemoteHost() async throws {
        let context = try #require(URL(string: "http://dav.example.org/"))
        let dav = CardDAVClient(
            context: context, credentials: DAVCredentials(user: "jk@example.org", password: "secret"),
            trustedHosts: ["dav.example.org"], session: session)
        await #expect(throws: DAVError.plainRefused) { try await dav.addressBooks() }
        await #expect(throws: DAVError.plainRefused) { try await dav.etags(context) }
    }

    @Test func plainHTTPOnlyToRealLoopback() async throws {
        for text in ["http://127.example.org/", "http://127.0.0.1.example.org/", "http://localhost.example.org/"] {
            let context = try #require(URL(string: text))
            let host = try #require(context.host())
            let dav = CardDAVClient(
                context: context, credentials: DAVCredentials(user: "jk@example.org", password: "secret"),
                trustedHosts: [host], session: session)
            await #expect(throws: DAVError.plainRefused) { try await dav.addressBooks() }
        }
    }

    @Test func offDomainRedirectSendsNoPassword() async throws {
        let (server, context) = try await start()
        // A trusted hop first (which needs the password), then off the domain.
        await server.redirectWellKnown(to: "/hop/")
        await server.redirect("/hop/", to: "https://other.example.net/dav/")
        let dav = client(context.appending(path: ".well-known/carddav"))
        await #expect(throws: DAVError.offDomainRedirect(host: "other.example.net")) { try await dav.addressBooks() }
        let requests = await server.requests
        await server.stop()
        #expect(requests.map(\.path) == ["/.well-known/carddav", "/hop/"])
        let expected = "Basic " + Data("jk@example.org:secret".utf8).base64EncodedString()
        #expect(requests.allSatisfy { $0.authorization == expected })
    }

    @Test func wellKnownProbeFindsTheContext() async throws {
        let (server, context) = try await start()
        let found = await WellKnown.probe(context.appending(path: ".well-known/carddav"), session: session)
        let requests = await server.requests
        await server.stop()
        #expect(found?.path() == "/principals/jk/")
        #expect(requests.count == 2, "\(requests)")
        #expect(requests.allSatisfy { $0.authorization == nil })
    }

    @Test func credentialsNeverPrint() {
        let credentials = DAVCredentials(user: "jk@example.org", password: "hunter2-secret")
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in [String(describing: credentials), String(reflecting: credentials), dumped] {
            #expect(!text.contains("hunter2"))
        }
    }
}
