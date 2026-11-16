// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightNet
import OutwrightModel
import OutwrightPush
@testable import OutwrightSync
import Synchronization
import Testing

/// A method that offers push or not, and when asked makes a handle of its own name.
private final class StandInMethod: PushMethod {
    let kind: PushMethodKind
    let offering: Bool
    let failing: PushError?
    let guide: URL?
    let subscribed = Mutex<[String]>([])
    let offerAsks = Mutex(0)
    /// The status of a relay call with the access each step was given, by step.
    let relayAnswers = Mutex<[String: Int]>([:])

    init(kind: PushMethodKind, offering: Bool, failing: PushError? = nil, guide: URL? = nil) {
        self.kind = kind
        self.offering = offering
        self.failing = failing
        self.guide = guide
    }

    func setupGuide(for account: Account) async -> URL? { guide }

    func offers(_ account: Account) async -> Bool {
        offerAsks.withLock { $0 += 1 }
        return offering
    }

    func subscribe(_ setup: PushSetup) async throws(PushError) -> String {
        if let failing {
            throw failing
        }
        subscribed.withLock { $0.append(setup.subscription.id) }
        await ask(setup.relay, step: "subscribe")
        return "handle-\(kind.rawValue)"
    }

    func renew(_ handle: String, account: Account, until: Date, relay: RelayAccess?) async -> PushRenewal {
        await ask(relay, step: "renew")
        return .kept
    }

    func remove(_ handle: String, account: Account, relay: RelayAccess?) async throws(PushError) {
        await ask(relay, step: "remove")
    }

    /// Asks the relay for the subscription's pending body, as its own device.
    private func ask(_ relay: RelayAccess?, step: String) async {
        guard let relay else { return }
        let status = (try? await relay.call("GET", "subscriptions/\(relay.subscription.id)/pending", nil))?.status
        relayAnswers.withLock { $0[step] = status ?? -1 }
    }
}

/// Hands out one access token, as a provider's token endpoint would.
private struct StubRenewal: TokenRefreshing {
    func refresh(_ token: Secret, for resource: OAuthResource) async throws(OAuthError) -> OAuthTokens {
        OAuthTokens(
            accessToken: Secret("stub-access"), refreshToken: token, expiresAt: Date().addingTimeInterval(3600),
            identity: nil)
    }
}

private struct AcceptingAttester: DeviceAttester {
    func keyID() async throws(PushError) -> String { "key" }
    func forgetKey() async {}
    func attest(keyID: String, challenge: String) async throws(PushError) -> Data { Data("attested".utf8) }
    func assert(keyID: String, challenge: String) async throws(PushError) -> Data { Data("asserted".utf8) }
}

private func withMethods(
    _ methods: [any PushMethod], oauth: Bool = false,
    _ body: (PushController, PushRegistry, Account) async throws -> Void
) async throws {
    try await withHarness { h in
        var account = h.account
        var tokens: [ProviderID: any TokenRefreshing] = [:]
        if oauth {
            account.auth = .oauth
            account.provider = ProviderID(raw: "stub")
            tokens[account.provider] = StubRenewal()
            try h.secrets.setRefreshToken(Secret("stub-refresh"), for: account.id)
            await h.imap.acceptToken("stub-access")
        }
        let relay = FakeRelay()
        let base = try await relay.start()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("outwright-push-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = PushRegistry(fileURL: folder.appendingPathComponent("push-registry.json"), vault: InMemoryPushVault())
        let controller = PushController(
            relay: RelayClient(base: base), attester: AcceptingAttester(), registry: registry,
            credentials: CredentialProvider(secrets: h.secrets, tokens: tokens),
            marks: PushWatermarks(fileURL: folder.appendingPathComponent("push-watermarks.json")),
            environment: .development, methods: methods,
            timing: PushTiming(poll: .milliseconds(20), verifyWithin: .seconds(2), backoffs: [.zero]))
        await controller.setDeviceToken(Data([0x01]))
        try await body(controller, registry, account)
        await relay.stop()
    }
}

@Suite struct PushMethodTests {
    @Test func oldRegistryFileReadsAsJMAP() async throws {
        try await withHarness { h in
            let old: [String: Any] = [
                "account": try JSONSerialization.jsonObject(with: JSONEncoder().encode(h.account)),
                "relay": ["id": "sub-1", "pushURL": "https://push.example.org/v1/push/sub-1"],
                "jmapID": "jmap-7"
            ]
            let data = try JSONSerialization.data(withJSONObject: old)
            let registration = try JSONDecoder().decode(PushRegistration.self, from: data)
            #expect(registration.method == .jmap)
            #expect(registration.handle == "jmap-7")
        }
    }

    @Test func firstOfferingMethodIsUsed() async throws {
        let refusing = StandInMethod(kind: PushMethodKind(rawValue: "first"), offering: false)
        let offering = StandInMethod(kind: PushMethodKind(rawValue: "second"), offering: true)
        try await withMethods([refusing, offering]) { controller, registry, account in
            #expect(await controller.offersPush(account))
            try await controller.enable(account)
            let registration = try #require(registry.registration(for: account.id))
            #expect(registration.method == PushMethodKind(rawValue: "second"))
            #expect(registration.handle == "handle-second")
            #expect(refusing.subscribed.withLock { $0 }.isEmpty)
            #expect(offering.subscribed.withLock { $0 } == [registration.relay.id])
        }
    }

    @Test func aMethodGetsRelayAccessForItsOwnSubscription() async throws {
        let offering = StandInMethod(kind: PushMethodKind(rawValue: "only"), offering: true)
        try await withMethods([offering]) { controller, _, account in
            try await controller.enable(account)
            await controller.renewAll()
            try await controller.disable(account.id)
            // The relay subscription is still there for every step, removal included.
            #expect(offering.relayAnswers.withLock { $0 } == ["subscribe": 204, "renew": 204, "remove": 204])
        }
    }

    @Test func theProbeSignsInWithTheProvidersTokens() async throws {
        let offering = StandInMethod(kind: PushMethodKind(rawValue: "only"), offering: true)
        try await withMethods([offering], oauth: true) { controller, registry, account in
            try await controller.enable(account)
            #expect(registry.registration(for: account.id) != nil)
        }
    }

    @Test func noMethodOffersMeansNoPush() async throws {
        let refusing = StandInMethod(kind: PushMethodKind(rawValue: "first"), offering: false)
        try await withMethods([refusing]) { controller, registry, account in
            #expect(await !controller.offersPush(account))
            await #expect(throws: PushError.self) {
                try await controller.enable(account)
            }
            #expect(registry.registration(for: account.id) == nil)
        }
    }

    @Test func disableRemovesThroughTheRegistrationsMethod() async throws {
        let offering = StandInMethod(kind: PushMethodKind(rawValue: "only"), offering: true)
        try await withMethods([offering]) { controller, registry, account in
            try await controller.enable(account)
            try await controller.disable(account.id)
            #expect(registry.registration(for: account.id) == nil)
        }
    }

    @Test func guideComesFromTheMethodTriedWithoutAskingAgain() async throws {
        let guide = try #require(URL(string: "https://example.org/guide"))
        let failing = StandInMethod(
            kind: PushMethodKind(rawValue: "guided"), offering: true, failing: .notSetUp, guide: guide)
        try await withMethods([failing]) { controller, _, account in
            await #expect(throws: PushError.notSetUp) {
                try await controller.enable(account)
            }
            let asked = failing.offerAsks.withLock { $0 }
            #expect(await controller.setupGuide(for: account) == guide)
            #expect(failing.offerAsks.withLock { $0 } == asked)
        }
    }
}
