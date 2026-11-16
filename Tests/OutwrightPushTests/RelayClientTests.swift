// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightPush

@Suite struct RelayClientTests {
    private func withRelay(_ body: (FakeRelay, RelayClient) async throws -> Void) async throws {
        let relay = FakeRelay()
        let base = try await relay.start()
        do {
            try await body(relay, RelayClient(base: base))
        } catch {
            await relay.stop()
            throw error
        }
        await relay.stop()
    }

    private func register(_ client: RelayClient) async throws -> RelayDevice {
        let challenge = try await client.challenge()
        return try await client.registerDevice(
            keyID: "key", attestation: Data([1, 2]), challenge: challenge, token: Data([0xab, 0xcd]),
            environment: .development)
    }

    private func subscribe(_ client: RelayClient, _ device: RelayDevice) async throws -> RelaySubscription {
        try await client.subscribe(challenge: try await client.challenge(), assertion: Data([9]), device: device)
    }

    @Test func deviceCallSendsTheBearerAndRejectsOddPaths() async throws {
        try await withRelay { relay, client in
            let device = try await register(client)
            let sub = try await subscribe(client, device)
            await relay.push(Data([7]), to: sub.id)
            let (status, body) = try await client.deviceCall("GET", "subscriptions/\(sub.id)/pending", body: nil, device: device)
            #expect(status == 200 && String(decoding: body, as: UTF8.self).contains(Data([7]).base64EncodedString()))
            let stranger = RelayDevice(deviceID: device.deviceID, secret: "wrong")
            let (refused, _) = try await client.deviceCall("GET", "subscriptions/\(sub.id)/pending", body: nil, device: stranger)
            #expect(refused == 401)
            let before = await relay.requestCount
            for path in ["subscriptions/../devices", "subscriptions/x?y=1", "subscriptions/%2e%2e", "", "a//b", "/a"] {
                await #expect(throws: PushError.malformed) {
                    _ = try await client.deviceCall("GET", path, body: nil, device: device)
                }
            }
            #expect(await relay.requestCount == before)
        }
    }

    @Test func registersAndSubscribes() async throws {
        try await withRelay { relay, client in
            let device = try await register(client)
            let sub = try await subscribe(client, device)
            #expect(sub.pushURL.absoluteString.hasPrefix(await relay.baseURL.absoluteString))
            #expect(await relay.subscriptions.contains(sub.id))
        }
    }

    @Test func eleventhSubscriptionIsLimit() async throws {
        try await withRelay { _, client in
            let device = try await register(client)
            for _ in 0..<10 {
                _ = try await subscribe(client, device)
            }
            await #expect(throws: PushError.limit) { try await subscribe(client, device) }
        }
    }

    @Test func pendingBodyIsNilUntilPushed() async throws {
        try await withRelay { relay, client in
            let device = try await register(client)
            let sub = try await subscribe(client, device)
            #expect(try await client.pendingBody(sub, device: device) == nil)
            await relay.push(Data([1, 2, 3]), to: sub.id)
            #expect(try await client.pendingBody(sub, device: device) == Data([1, 2, 3]))
        }
    }

    @Test func activateClearsPending() async throws {
        try await withRelay { relay, client in
            let device = try await register(client)
            let sub = try await subscribe(client, device)
            await relay.push(Data([1]), to: sub.id)
            try await client.activate(sub, device: device)
            #expect(try await client.pendingBody(sub, device: device) == nil)
            #expect(await relay.held.isEmpty)
        }
    }

    @Test func rateLimitedMapsTo429() async throws {
        try await withRelay { relay, client in
            await relay.force(.json(429, "{\"error\":\"rate\"}"))
            await #expect(throws: PushError.rateLimited) { try await client.challenge() }
        }
    }

    @Test func attestRefusalMapsToAttest() async throws {
        try await withRelay { relay, client in
            await relay.force(.json(403, "{\"error\":\"attest\"}"))
            await #expect(throws: PushError.attest) { try await client.challenge() }
            await relay.force(.json(401, "{\"error\":\"unauthorized\"}"))
            await #expect(throws: PushError.http(401)) { try await client.challenge() }
        }
    }

    @Test func responseOver64KiBIsMalformed() async throws {
        try await withRelay { relay, client in
            await relay.force(.json(200, "{\"challenge\":\"" + String(repeating: "a", count: 70_000) + "\"}"))
            await #expect(throws: PushError.malformed) { try await client.challenge() }
        }
    }

    @Test func garbageJSONIsMalformed() async throws {
        try await withRelay { relay, client in
            await relay.force(.json(200, "not json at all"))
            await #expect(throws: PushError.malformed) { try await client.challenge() }
        }
    }

    @Test func plainHTTPToARemoteHostIsRefused() async throws {
        let client = RelayClient(base: try #require(URL(string: "http://relay.example.org/v1")))
        await #expect(throws: PushError.transport) { try await client.challenge() }
    }
}
