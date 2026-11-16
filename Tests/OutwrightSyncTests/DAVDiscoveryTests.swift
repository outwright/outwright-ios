// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// Remembers every URL probed and answers for the ones in `answers`.
private final class Probe: Sendable {
    private let answers: [String: String]
    private let log = Mutex<[String]>([])

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    var asked: [String] { log.withLock { $0 } }

    func callAsFunction(_ url: URL) async -> URL? {
        log.withLock { $0.append(url.absoluteString) }
        return answers[url.absoluteString].flatMap(URL.init(string:))
    }
}

/// The well-known name of a service: `carddav` or `caldav`.
private func name(_ service: DAVService) -> String {
    service == .cardDAV ? "carddav" : "caldav"
}

/// The harness's account with the other service turned off, so that only `service` is looked for.
private func only(_ service: DAVService, _ h: Harness) throws {
    var account = h.account
    account.cardDAVOff = service != .cardDAV
    account.calDAVOff = service != .calDAV
    try h.store.save(account)
}

private func account(email: String = "jk@example.org", imap: String = "imap.example.org") -> Account {
    Account(
        id: AccountID(), displayName: "Jörgen", email: email, colorIndex: 0,
        imap: MailEndpoint(host: imap, port: 993, security: "tls"),
        smtp: MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"),
        user: email, signature: "", sortOrder: 0)
}

/// Every request a session made, answered 401 with nothing, so no request leaves the process.
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    // swiftlint:disable:next large_tuple
    static let seen = Mutex<[(host: String, path: String, authorization: String?)]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock {
            $0.append((
                request.url?.host() ?? "", request.url?.path() ?? "",
                request.value(forHTTPHeaderField: "Authorization")))
        }
        let url = request.url ?? URL(filePath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers by host: the status in `statuses`, else 404.
final class StatusProtocol: URLProtocol, @unchecked Sendable {
    static let statuses = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(filePath: "/")
        let status = Self.statuses.withLock { $0[url.host() ?? ""] } ?? 404
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct DAVDiscoveryTests {
    static let services: [DAVService] = [.cardDAV, .calDAV]

    @Test(arguments: services) func catchAllWebsiteDoesNotWin(_ service: DAVService) async throws {
        StatusProtocol.statuses.withLock { $0 = ["example.org": 200, "imap.example.org": 401] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusProtocol.self]
        let session = URLSession(configuration: configuration)
        let found = await DAVDiscovery.find(
            service, for: account(), resolver: FakeDoH(), probe: { await WellKnown.probe($0, session: session) })
        #expect(found?.url == "https://imap.example.org/.well-known/\(name(service))")
    }

    @Test(arguments: services) func srvTargetIsUsed(_ service: DAVService) async throws {
        let resolver = FakeDoH([
            "_\(name(service))s._tcp.example.org": [(target: "dav.example.org.", port: 8443, priority: 0)],
        ])
        let probe = Probe([
            "https://dav.example.org:8443/.well-known/\(name(service))": "https://dav.example.org:8443/dav/",
        ])
        let found = await DAVDiscovery.find(service, for: account(), resolver: resolver, probe: { await probe($0) })
        #expect(found == DAVFound(url: "https://dav.example.org:8443/dav/", offDomain: false))
        #expect(probe.asked == ["https://dav.example.org:8443/.well-known/\(name(service))"])
    }

    @Test func eachServiceAsksItsOwnRecord() async throws {
        let resolver = FakeDoH(["_carddavs._tcp.example.org": [(target: "dav.example.org.", port: 8443, priority: 0)]])
        let probe = Probe([:])
        _ = await DAVDiscovery.find(.calDAV, for: account(), resolver: resolver, probe: { await probe($0) })
        #expect(probe.asked == [
            "https://example.org/.well-known/caldav", "https://imap.example.org/.well-known/caldav",
        ])
    }

    @Test(arguments: services) func wellKnownOnDomainIsUsed(_ service: DAVService) async throws {
        let probe = Probe(["https://example.org/.well-known/\(name(service))": "https://example.org/dav/"])
        let found = await DAVDiscovery.find(service, for: account(), resolver: FakeDoH(), probe: { await probe($0) })
        #expect(found == DAVFound(url: "https://example.org/dav/", offDomain: false))
    }

    @Test(arguments: services) func imapHostIsTriedLast(_ service: DAVService) async throws {
        let probe = Probe(["https://imap.example.org/.well-known/\(name(service))": "https://imap.example.org/dav/"])
        let found = await DAVDiscovery.find(service, for: account(), resolver: FakeDoH(), probe: { await probe($0) })
        #expect(found?.url == "https://imap.example.org/dav/")
        #expect(probe.asked == [
            "https://example.org/.well-known/\(name(service))", "https://imap.example.org/.well-known/\(name(service))",
        ])
        let none = await DAVDiscovery.find(service, for: account(), resolver: FakeDoH(), probe: { _ in nil })
        #expect(none == nil)
    }

    @Test(arguments: services) func imapHostCountsAsTrusted(_ service: DAVService) async throws {
        let owner = account(email: "jk@agiletto.example.org", imap: "mail.host.example.net")
        let probe = Probe([
            "https://mail.host.example.net/.well-known/\(name(service))": "https://mail.host.example.net/dav/",
        ])
        let found = await DAVDiscovery.find(service, for: owner, resolver: FakeDoH(), probe: { await probe($0) })
        #expect(found == DAVFound(url: "https://mail.host.example.net/dav/", offDomain: false))
    }

    @Test(arguments: services) func redirectElsewhereIsOffDomain(_ service: DAVService) async throws {
        let probe = Probe(["https://example.org/.well-known/\(name(service))": "https://dav.other.example.net/dav/"])
        let found = await DAVDiscovery.find(service, for: account(), resolver: FakeDoH(), probe: { await probe($0) })
        #expect(found == DAVFound(url: "https://dav.other.example.net/dav/", offDomain: true))
    }

    @Test func offDomainDiscoveryWaitsForConfirmation() async throws {
        RecordingProtocol.seen.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolver = FakeDoH(["_carddavs._tcp.example.org": [(target: "dav.other.example.net.", port: 443, priority: 0)]])
        try await withHarness { h in
            try only(.cardDAV, h)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: resolver, davSession: session,
                probe: { await WellKnown.probe($0, session: session) })
            await coordinator.refreshAll()
            let saved = try #require(try h.store.accounts().first { $0.id == h.account.id })
            #expect(saved.cardDAV == nil)
            #expect(saved.cardDAVUnconfirmed == "https://dav.other.example.net/.well-known/carddav")
            let seen = RecordingProtocol.seen.withLock { $0 }
            #expect(seen.map(\.host) == ["dav.other.example.net"])
            #expect(seen.allSatisfy { $0.authorization == nil })

            // Discovery runs once per process.
            await coordinator.refreshAll()
            #expect(RecordingProtocol.seen.withLock { $0.count } == 1)
        }
    }

    @Test func calDAVOffDomainWaitsForConfirmation() async throws {
        RecordingProtocol.seen.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolver = FakeDoH(["_caldavs._tcp.example.org": [(target: "dav.other.example.net.", port: 443, priority: 0)]])
        try await withHarness { h in
            try only(.calDAV, h)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: resolver, davSession: session,
                probe: { await WellKnown.probe($0, session: session) })
            await coordinator.refreshAll()
            let saved = try #require(try h.store.accounts().first { $0.id == h.account.id })
            #expect(saved.calDAV == nil)
            #expect(saved.calDAVUnconfirmed == "https://dav.other.example.net/.well-known/caldav")
            let seen = RecordingProtocol.seen.withLock { $0 }
            #expect(seen.map(\.host) == ["dav.other.example.net"])
            #expect(seen.allSatisfy { $0.authorization == nil })

            // Discovery runs once per process.
            await coordinator.refreshAll()
            #expect(RecordingProtocol.seen.withLock { $0.count } == 1)
        }
    }

    @Test func calDAVOffIsNotLookedFor() async throws {
        let probe = Probe([:])
        try await withHarness { h in
            var account = h.account
            account.cardDAVOff = true
            account.calDAVOff = true
            try h.store.save(account)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: FakeDoH(), probe: { await probe($0) })
            await coordinator.refreshAll()
            #expect(probe.asked.isEmpty)
        }
    }

    /// A Microsoft account's contacts and calendar come through Graph, never CardDAV or CalDAV:
    /// neither is looked for.
    @Test func microsoftAccountLooksForNoDAV() async throws {
        let probe = Probe([
            "https://example.org/.well-known/carddav": "https://example.org/dav/",
            "https://example.org/.well-known/caldav": "https://example.org/dav/",
        ])
        try await withHarness { h in
            var microsoft = h.account
            microsoft.auth = .oauth
            microsoft.provider = testOAuthProvider
            microsoft.calendarVia = .graph
            microsoft.contactsVia = .graph
            try h.store.save(microsoft)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: FakeDoH(), probe: { await probe($0) })
            await coordinator.refreshAll()
            #expect(probe.asked.isEmpty)
            let saved = try #require(try h.store.accounts().first { $0.id == h.account.id })
            #expect(saved.cardDAV == nil && saved.cardDAVUnconfirmed == nil)
            #expect(saved.calDAV == nil && saved.calDAVUnconfirmed == nil)
        }
    }

    @Test func onDomainDiscoverySetsCardDAVAndSyncs() async throws {
        let server = FakeCardDAVServer()
        let port = try await server.start()
        let book = await server.addBook("Work")
        await server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
        let resolver = FakeDoH(["_carddavs._tcp.example.org": [(target: "127.0.0.1.", port: port, priority: 0)]])
        try await withHarness { h in
            try only(.cardDAV, h)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: resolver,
                davSession: URLSession(configuration: .ephemeral), probe: plainLoopback)
            await coordinator.refreshAll()
            let saved = try #require(try h.store.accounts().first { $0.id == h.account.id })
            #expect(saved.cardDAV != nil)
            #expect(try h.store.contacts(in: nil, matching: nil).map(\.details.name) == ["Bo Berg"])
        }
        await server.stop()
    }

    @Test func onDomainDiscoverySetsCalDAVAndSyncs() async throws {
        let server = FakeCalDAVServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let port = try await server.start()
        let work = await server.addCalendar("Work")
        await server.putEvent(eventText("a", title: "Planning"), uid: "a", in: work)
        let resolver = FakeDoH(["_caldavs._tcp.example.org": [(target: "127.0.0.1.", port: port, priority: 0)]])
        try await withHarness { h in
            try only(.calDAV, h)
            let coordinator = offlineCoordinator(
                store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: resolver,
                davSession: URLSession(configuration: .ephemeral), probe: plainLoopback)
            await coordinator.refreshAll()
            let saved = try #require(try h.store.accounts().first { $0.id == h.account.id })
            #expect(saved.calDAV != nil)
            let held = try h.store.occurrences(
                from: fixedNow, to: fixedNow.addingTimeInterval(7 * 86_400), in: nil)
            #expect(held.map(\.occurrence.details.title) == ["Planning"])
        }
        await server.stop()
    }
}

/// The fakes speak plain HTTP on loopback: the probe asks there, and finds nothing anywhere else.
private let plainLoopback: @Sendable (URL) async -> URL? = { url in
    guard url.host() == "127.0.0.1" else { return nil }
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    parts?.scheme = "http"
    guard let plain = parts?.url else { return nil }
    return await WellKnown.probe(plain, session: URLSession(configuration: .ephemeral))
}
