// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Synchronization
import Testing

@testable import OutwrightGraph

/// A notification endpoint on loopback: it echoes Graph's validation token (unless told not to)
/// and keeps the notifications posted to it.
private final class Endpoint: Sendable {
    final class State: Sendable {
        let echo = Mutex(true)
        let posts = Mutex<[Data]>([])
    }

    let state = State()
    let server: FakeHTTPServer

    init() {
        let state = self.state
        server = FakeHTTPServer { request in
            let query = URLComponents(string: "http://x" + request.path)?.queryItems ?? []
            if let token = query.first(where: { $0.name == "validationToken" })?.value {
                guard state.echo.withLock({ $0 }) else { return FakeHTTPResponse(status: 404) }
                return FakeHTTPResponse(status: 200, body: Data(token.utf8), headers: ["Content-Type": "text/plain"])
            }
            state.posts.withLock { $0.append(request.body) }
            return FakeHTTPResponse(status: 202)
        }
    }

    func start() async throws -> URL {
        let port = try await server.start()
        return try #require(URL(string: "http://127.0.0.1:\(port)/v1/graph/channel-1"))
    }
}

private let inbox = "me/mailFolders('inbox')/messages"

@Suite struct GraphSubscriptionTests {
    private func create(
        _ client: GraphClient, _ url: URL, resource: String = inbox
    ) async throws(GraphError) -> GraphSubscription {
        try await client.createSubscription(
            GraphSubscriptionRequest(
                resource: resource, changeType: "created", notificationURL: url,
                lifecycleURL: url.appending(path: "lifecycle"), clientState: "state-1"),
            expires: Date().addingTimeInterval(10_070 * 60))
    }

    @Test func createValidatesAndReturnsTheSubscription() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            let made = try await create(client, url)
            #expect(made.resource == inbox && made.changeType == "created" && made.notificationURL == url)
            #expect(abs(made.expires.timeIntervalSinceNow - 10_070 * 60) < 60)
            #expect(await server.subscriptions.map(\.id) == [made.id])
            await server.deliverNewMail()
            let post = try #require(endpoint.state.posts.withLock { $0.first })
            let value = try #require(
                ((try JSONSerialization.jsonObject(with: post)) as? [String: Any])?["value"] as? [[String: Any]])
            #expect(value.first?["clientState"] as? String == "state-1")
            #expect(value.first?["subscriptionId"] as? String == made.id)
        }
        endpoint.server.stop()
    }

    @Test func aDuplicateIsConflict() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { _, client, _ in
            _ = try await create(client, url)
            await #expect(throws: GraphError.conflict) { try await create(client, url) }
        }
        endpoint.server.stop()
    }

    @Test func anUnechoedValidationFailsTheCreate() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        endpoint.state.echo.withLock { $0 = false }
        try await withGraph { server, client, _ in
            await #expect(throws: GraphError.status(400)) { try await create(client, url) }
            #expect(await server.subscriptions.isEmpty)
        }
        endpoint.server.stop()
    }

    @Test func forbiddenIsForbidden() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            await server.refuseSubscriptions(with: 403)
            await #expect(throws: GraphError.forbidden) { try await create(client, url) }
        }
        endpoint.server.stop()
    }

    @Test func aPlainOffLoopbackURLIsRefused() async throws {
        try await withGraph { server, client, _ in
            let url = try #require(URL(string: "http://relay.example.org/v1/graph/c"))
            await #expect(throws: GraphError.malformed) { try await create(client, url) }
            #expect(await server.requests.isEmpty)
        }
    }

    @Test func renewMovesTheExpiry() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            let made = try await create(client, url)
            let later = Date().addingTimeInterval(10_000 * 60)
            let expires = try await client.renewSubscription(made.id, expires: later)
            #expect(abs(expires.timeIntervalSince(later)) < 1)
            #expect(abs((await server.subscriptions.first?.expires ?? .distantPast).timeIntervalSince(later)) < 1)
        }
        endpoint.server.stop()
    }

    @Test func aMissingSubscriptionIsNotFound() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            let made = try await create(client, url)
            await server.dropSubscriptions()
            await #expect(throws: GraphError.notFound) {
                _ = try await client.renewSubscription(made.id, expires: Date().addingTimeInterval(3600))
            }
            await #expect(throws: GraphError.notFound) { try await client.deleteSubscription(made.id) }
        }
        endpoint.server.stop()
    }

    @Test func deleteRemovesIt() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            let made = try await create(client, url)
            try await client.deleteSubscription(made.id)
            #expect(await server.subscriptions.isEmpty)
        }
        endpoint.server.stop()
    }

    @Test func listingReadsEveryPage() async throws {
        let endpoint = Endpoint()
        let url = try await endpoint.start()
        try await withGraph { server, client, _ in
            await server.setPageSize(1)
            var made: [GraphSubscription] = []
            for resource in [inbox, "me/messages", "me/events"] {
                made.append(try await create(client, url, resource: resource))
            }
            #expect(try await client.subscriptions() == made)
        }
        endpoint.server.stop()
    }

    @Test func readsGraphsSevenDigitFractions() throws {
        let data = Data(#"""
            {"id":"s1","resource":"me/messages","changeType":"created",
             "notificationUrl":"https://push.example.org/v1/graph/c","expirationDateTime":"2026-11-20T18:23:45.9356913Z"}
            """#.utf8)
        let made = try GraphSubscriptions.subscription(data)
        #expect(made.expires.timeIntervalSince1970.rounded(.down) == 1_795_199_025)
    }

    @Test func subscriptionAnswersSurviveArbitraryBytes() {
        var generator = SystemRandomNumberGenerator()
        let pieces = [#"{"value":["#, #"{"id":"#, #""x""#, "1", "null", "[", "]", "{", "}", ",", ":",
                      #""notificationUrl""#, #""expirationDateTime""#, #""2026-11-20T18:23:45.9Z""#,
                      #""https://a/b""#, #""resource""#, #""changeType""#, "true", #""\u0000""#]
        for _ in 0..<2000 {
            var data = Data()
            if Bool.random(using: &generator) {
                data = Data((0..<Int.random(in: 0..<64, using: &generator)).map { _ in
                    UInt8.random(in: 0...255, using: &generator)
                })
            } else {
                let count = Int.random(in: 0..<24, using: &generator)
                data = Data((0..<count).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined().utf8)
            }
            do {
                _ = try GraphSubscriptions.subscription(data)
            } catch {
                #expect(error == .malformed)
            }
            do {
                _ = try GraphSubscriptions.page(data)
            } catch {
                #expect(error == .malformed)
            }
        }
    }
}
