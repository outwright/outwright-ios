// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import OutwrightPush
import Testing

@testable import OutwrightJMAP

@Suite struct PushSubscriptionTests {
    private let keys = (p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", auth: "BTBZMqHH6r4Tts7J_aSIgg")
    private let pushURL = URL(string: "http://127.0.0.1:1/v1/push/abc")

    private func withServer(_ body: (FakeJMAPServer, String) async throws -> Void) async throws {
        let server = FakeJMAPServer()
        let host = try await server.start()
        do {
            try await body(server, host)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func client(_ server: FakeJMAPServer, _ host: String) async throws -> JMAPClient {
        try await JMAPClient.discover(host: host, user: server.user, password: Secret(server.password))
    }

    private func create(_ jmap: JMAPClient, url: URL? = nil) async throws -> String {
        try await jmap.createPushSubscription(
            deviceClientID: "device-1", url: try #require(url ?? pushURL), keys: keys,
            expires: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func discoversSessionAndApiUrl() async throws {
        try await withServer { server, host in
            let jmap = try await client(server, host)
            // The session is behind a redirect; an id back proves the api url was read from it.
            let id = try await create(jmap)
            #expect(await server.subscriptions[id] != nil)
        }
    }

    @Test func createsEmailDeliverySubscription() async throws {
        try await withServer { server, host in
            let id = try await create(try await client(server, host))
            let sub = try #require(await server.subscriptions[id])
            #expect(sub.types == ["EmailDelivery"])
            #expect(sub.p256dh == keys.p256dh)
            #expect(sub.auth == keys.auth)
            #expect(sub.deviceClientID == "device-1")
            #expect(sub.expires == "2027-01-15T08:00:00Z")
        }
    }

    @Test func verifySendsCode() async throws {
        try await withServer { server, host in
            let jmap = try await client(server, host)
            let id = try await create(jmap)
            await #expect(throws: JMAPError.refused) { try await jmap.verify(id, code: "wrong") }
            let code = try #require(await server.subscriptions[id]?.verificationCode)
            try await jmap.verify(id, code: code)
            #expect(await server.subscriptions[id]?.verified == true)
        }
    }

    @Test func renewMovesExpiry() async throws {
        try await withServer { server, host in
            let jmap = try await client(server, host)
            let id = try await create(jmap)
            try await jmap.renew(id, expires: Date(timeIntervalSince1970: 1_900_000_000))
            #expect(await server.subscriptions[id]?.expires == "2030-03-17T17:46:40Z")
        }
    }

    @Test func renewOfASubscriptionTheServerLostIsNotFound() async throws {
        try await withServer { server, host in
            let jmap = try await client(server, host)
            let id = try await create(jmap)
            await server.forget(id)
            await #expect(throws: JMAPError.notFound) {
                try await jmap.renew(id, expires: Date(timeIntervalSince1970: 1_900_000_000))
            }
        }
    }

    @Test func destroyRemoves() async throws {
        try await withServer { server, host in
            let jmap = try await client(server, host)
            let id = try await create(jmap)
            try await jmap.destroy(id)
            #expect(await server.subscriptions.isEmpty)
            await #expect(throws: JMAPError.refused) { try await jmap.destroy(id) }
        }
    }

    @Test func refusesNonLoopbackHTTP() async throws {
        // A remote host is always reached over https; a session that names plain http for it is refused.
        let endpoint = try JMAPEndpoint("mail.example.org")
        #expect(endpoint.scheme == "https")
        #expect(!endpoint.owns(try #require(URL(string: "http://mail.example.org/jmap/"))))
        #expect(!endpoint.owns(try #require(URL(string: "https://other.example.org/jmap/"))))
        #expect(endpoint.owns(try #require(URL(string: "https://mail.example.org/jmap/"))))
        #expect(try JMAPEndpoint("127.0.0.1:9").scheme == "http")
    }

    @Test func apiUrlOnAnotherHostIsMalformed() async throws {
        try await withServer { server, host in
            await server.forceSession(
                .json(200, "{\"apiUrl\":\"http://localhost:1/jmap/\"}"))
            await #expect(throws: JMAPError.malformed) { try await client(server, host) }
        }
    }

    @Test func wrongPasswordIsAuth() async throws {
        try await withServer { server, host in
            await #expect(throws: JMAPError.auth) {
                try await JMAPClient.discover(host: host, user: server.user, password: Secret("nope"))
            }
        }
    }

    /// Stalwart answers 200 with an anonymous session (empty username) instead of 401.
    @Test func anonymousSessionIsAuth() async throws {
        try await withServer { server, host in
            await server.forceSession(
                .json(200, "{\"apiUrl\":\"http://\(host)/jmap/\",\"accounts\":{},\"username\":\"\"}"))
            await #expect(throws: JMAPError.auth) { try await client(server, host) }
        }
    }

    @Test func sessionOver1MiBIsMalformed() async throws {
        try await withServer { server, host in
            await server.forceSession(
                .json(200, "{\"apiUrl\":\"http://\(host)/jmap/\",\"pad\":\"" + String(repeating: "a", count: 1 << 20) + "\"}"))
            await #expect(throws: JMAPError.malformed) { try await client(server, host) }
        }
    }

    @Test func errorsNeverCarryThePassword() {
        let secret = Secret("hunter2-secret")
        for error in [JMAPError.auth, .http(500), .malformed, .insecure, .refused, .transport, .timeout] {
            #expect(!"\(error)".contains("hunter2"))
        }
        #expect(!"\(secret)".contains("hunter2"))
    }

    // MARK: - The loop through the relay

    @Test func verificationAndStateChangeDecryptAtTheRelay() async throws {
        let relay = FakeRelay()
        let base = try await relay.start()
        let server = FakeJMAPServer()
        let host = try await server.start()
        let relayClient = RelayClient(base: base)
        do {
            let device = try await relayClient.registerDevice(
                keyID: "k", attestation: Data([1]), challenge: try await relayClient.challenge(),
                token: Data([0xab]), environment: .development)
            let sub = try await relayClient.subscribe(
                challenge: try await relayClient.challenge(), assertion: Data([1]), device: device)
            let webPush = WebPushKeys.generate()
            let jmap = try await client(server, host)
            let id = try await jmap.createPushSubscription(
                deviceClientID: "d", url: sub.pushURL, keys: (webPush.p256dh, webPush.authString),
                expires: Date(timeIntervalSince1970: 1_800_000_000))

            #expect(await server.sendVerification(id, to: relay) == 201)
            let held = try #require(try await relayClient.pendingBody(sub, device: device))
            let plain = try decryptWebPush(held, keys: webPush)
            let code = try #require(pushVerificationCode(from: plain, subscriptionID: id))
            #expect(pushVerificationCode(from: plain, subscriptionID: "other") == nil)
            try await jmap.verify(id, code: code)

            // A second subscription is left pending at the relay so the StateChange stays readable.
            let second = try await relayClient.subscribe(
                challenge: try await relayClient.challenge(), assertion: Data([1]), device: device)
            let other = try await jmap.createPushSubscription(
                deviceClientID: "d", url: second.pushURL, keys: (webPush.p256dh, webPush.authString),
                expires: Date(timeIntervalSince1970: 1_800_000_000))
            try await jmap.verify(other, code: try #require(await server.subscriptions[other]?.verificationCode))
            #expect(await server.deliverEmail(other, to: relay) == 201)
            let state = try decryptWebPush(
                try #require(try await relayClient.pendingBody(second, device: device)), keys: webPush)
            let object = try #require(try JSONSerialization.jsonObject(with: state) as? [String: Any])
            #expect(object["@type"] as? String == "StateChange")
            let changed = try #require(object["changed"] as? [String: [String: String]])
            #expect(changed.values.first?["EmailDelivery"] != nil)
        } catch {
            await relay.stop()
            await server.stop()
            throw error
        }
        await relay.stop()
        await server.stop()
    }

    // MARK: - Hostile input

    @Test func verificationCodeParserNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let count = Int.random(in: 0...200, using: &rng)
            let bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            #expect(pushVerificationCode(from: bytes, subscriptionID: "x") == nil)
        }
        let huge = Data(repeating: 0x20, count: 20_000)
        #expect(pushVerificationCode(from: huge, subscriptionID: "x") == nil)
        let good = Data(
            "{\"@type\":\"PushVerification\",\"pushSubscriptionId\":\"x\",\"verificationCode\":\"c\"}".utf8)
        #expect(pushVerificationCode(from: good, subscriptionID: "x") == "c")
    }
}
