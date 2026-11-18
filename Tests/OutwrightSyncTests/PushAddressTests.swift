// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightPush
@testable import OutwrightSync
import Synchronization
import Testing

/// An addressed method that hands out one address and checks as told.
private final class StandInAddressed: AddressedPushMethod {
    let kind = PushMethodKind(rawValue: "addressed")
    let address: PushAddress
    let checkFails = Mutex<PushError?>(nil)
    let renewal = Mutex<PushRenewal>(.kept)
    let joinable = Mutex(true)
    let subscribed = Mutex<[String]>([])
    let issued = Mutex(0)
    let joined = Mutex(0)
    let removed = Mutex<[String]>([])

    init() throws {
        address = PushAddress(
            handle: "channel-1",
            url: try #require(URL(string: "https://push.example.org/v1/channels/channel-1/plain")))
    }

    func setupGuide(for account: Account) async -> URL? { nil }
    func offers(_ account: Account) async -> Bool { true }

    func recognizes(_ url: URL, relayBase: URL) -> Bool {
        url.host() == "push.example.org" && url.lastPathComponent == "plain"
    }

    func issue(relay: RelayAccess) async throws(PushError) -> PushAddress {
        issued.withLock { $0 += 1 }
        return address
    }

    func join(_ url: URL, relay: RelayAccess) async throws(PushError) -> PushAddress? {
        joined.withLock { $0 += 1 }
        return url == address.url && joinable.withLock({ $0 }) ? address : nil
    }

    func subscribe(_ setup: PushSetup) async throws(PushError) -> String {
        guard let address = setup.address else {
            throw .unsupported
        }
        if let failure = checkFails.withLock({ $0 }) {
            throw failure
        }
        subscribed.withLock { $0.append(setup.subscription.id) }
        return address.handle
    }

    func renew(_ handle: String, account: Account, until: Date, relay: RelayAccess?) async -> PushRenewal {
        renewal.withLock { $0 }
    }

    func remove(_ handle: String, account: Account, relay: RelayAccess?) async throws(PushError) {
        removed.withLock { $0.append(handle) }
    }
}

/// An automatic method that offers push, as Dovecot's or JMAP's does.
private final class StandInAutomatic: PushMethod {
    let kind = PushMethodKind(rawValue: "automatic")
    let removed = Mutex(0)
    func setupGuide(for account: Account) async -> URL? { nil }
    func offers(_ account: Account) async -> Bool { true }
    func subscribe(_ setup: PushSetup) async throws(PushError) -> String { "auto" }
    func renew(_ handle: String, account: Account, until: Date, relay: RelayAccess?) async -> PushRenewal { .kept }
    func remove(_ handle: String, account: Account, relay: RelayAccess?) async throws(PushError) {
        removed.withLock { $0 += 1 }
    }
}

private struct AcceptingAttester: DeviceAttester {
    func keyID() async throws(PushError) -> String { "key" }
    func forgetKey() async {}
    func attest(keyID: String, challenge: String) async throws(PushError) -> Data { Data("attested".utf8) }
    func assert(keyID: String, challenge: String) async throws(PushError) -> Data { Data("asserted".utf8) }
}

private struct Rig {
    let relay: FakeRelay
    let registry: PushRegistry
    let account: Account
    let make: @Sendable () async -> PushController
}

private func withAddressed(
    _ method: StandInAddressed, also: [any PushMethod] = [], _ body: (PushController, Rig) async throws -> Void
) async throws {
    try await withHarness { harness in
        let relay = FakeRelay()
        let base = try await relay.start()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("outwright-push-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = PushRegistry(
            fileURL: folder.appendingPathComponent("push-registry.json"), vault: InMemoryPushVault())
        let secrets = harness.secrets
        let make: @Sendable () async -> PushController = {
            let controller = PushController(
                relay: RelayClient(base: base), attester: AcceptingAttester(), registry: registry,
                credentials: CredentialProvider(secrets: secrets, tokens: [:]),
                marks: PushWatermarks(fileURL: folder.appendingPathComponent("push-watermarks.json")),
                environment: .development, methods: also + [method],
                timing: PushTiming(poll: .milliseconds(20), verifyWithin: .seconds(2), backoffs: [.zero]))
            await controller.setDeviceToken(Data([0x01]))
            return controller
        }
        try await body(await make(), Rig(relay: relay, registry: registry, account: harness.account, make: make))
        await relay.stop()
    }
}

@Suite struct PushAddressTests {
    @Test func issueKeepsAddressAcrossRelaunch() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let url = try await controller.issueAddress(rig.account, joining: nil)
            #expect(url == method.address.url)
            let again = await rig.make()
            #expect(await again.address(for: rig.account.id) == url)
            #expect(try await again.issueAddress(rig.account, joining: nil) == url)
            #expect(await rig.relay.subscriptions.count == 1)
            #expect(method.issued.withLock { $0 } == 1)
        }
    }

    @Test func enableWithIssuedAddressRunsCheck() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let url = try await controller.issueAddress(rig.account, joining: nil)
            #expect(await controller.offersPush(rig.account))
            try await controller.enable(rig.account)
            let registration = try #require(rig.registry.registration(for: rig.account.id))
            #expect(registration.address == url)
            #expect(registration.handle == method.address.handle)
            #expect(method.subscribed.withLock { $0 } == [registration.relay.id])
            #expect(await rig.relay.subscriptions.count == 1)
            #expect(await rig.relay.isActive(registration.relay.id))
            #expect(await controller.address(for: rig.account.id) == url)
        }
    }

    @Test func failedCheckKeepsAddress() async throws {
        let method = try StandInAddressed()
        method.checkFails.withLock { $0 = .notSetUp }
        try await withAddressed(method) { controller, rig in
            let url = try await controller.issueAddress(rig.account, joining: nil)
            await #expect(throws: PushError.notSetUp) {
                try await controller.enable(rig.account)
            }
            #expect(await !controller.isEnabled(rig.account.id))
            #expect(await controller.address(for: rig.account.id) == url)
            #expect(await rig.relay.subscriptions.count == 1)
            method.checkFails.withLock { $0 = nil }
            try await controller.enable(rig.account)
            #expect(await controller.isEnabled(rig.account.id))
            #expect(await rig.relay.subscriptions.count == 1)
        }
    }

    @Test func joinUnknownAddressThrows() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let other = try #require(URL(string: "https://push.example.org/v1/channels/other/plain"))
            await #expect(throws: PushError.unknownAddress) {
                _ = try await controller.issueAddress(rig.account, joining: other)
            }
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(await rig.relay.subscriptions.isEmpty)
        }
    }

    @Test func joiningUsesTheGivenAddress() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let url = try await controller.issueAddress(rig.account, joining: method.address.url)
            #expect(url == method.address.url)
            #expect(method.joined.withLock { $0 } == 1)
            #expect(method.issued.withLock { $0 } == 0)
        }
    }

    @Test func removeAddressEndsIssued() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.removeAddress(rig.account.id)
            #expect(method.removed.withLock { $0 } == [method.address.handle])
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(await !controller.offersPush(rig.account))
        }
    }

    @Test func removeAddressEndsRegistered() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            try await controller.removeAddress(rig.account.id)
            #expect(await !controller.isEnabled(rig.account.id))
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await controller.address(for: rig.account.id) == nil)
        }
    }

    @Test func disableEndsAddress() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            try await controller.disable(rig.account.id)
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(await rig.relay.subscriptions.isEmpty)
        }
    }

    @Test func renewGoneSwitchesOff() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            method.renewal.withLock { $0 = .gone }
            await controller.renewAll()
            #expect(await !controller.isEnabled(rig.account.id))
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(method.subscribed.withLock { $0 }.count == 1)
            #expect(method.issued.withLock { $0 } == 1)
        }
    }

    @Test func relayLostRejoins() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            let old = try #require(rig.registry.registration(for: rig.account.id)).relay.id
            await rig.relay.forgetSubscription(old)
            await controller.renewAll()
            let now = try #require(rig.registry.registration(for: rig.account.id))
            #expect(now.relay.id != old)
            #expect(now.address == method.address.url)
            #expect(method.joined.withLock { $0 } == 1)
            #expect(await rig.relay.isActive(now.relay.id))
        }
    }

    @Test func relayLostAndAddressGoneSwitchesOff() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            let old = try #require(rig.registry.registration(for: rig.account.id)).relay.id
            await rig.relay.forgetSubscription(old)
            method.joinable.withLock { $0 = false }
            await controller.renewAll()
            #expect(await !controller.isEnabled(rig.account.id))
            #expect(await rig.relay.subscriptions.isEmpty)
        }
    }

    @Test func automaticChoiceSkipsAddressed() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            #expect(await !controller.offersPush(rig.account))
            #expect(await controller.addressOffered(rig.account))
            await #expect(throws: PushError.unsupported) {
                try await controller.enable(rig.account)
            }
        }
    }

    @Test func pasteNotOursMakesNoRelayCall() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let before = await rig.relay.requestCount
            let garbage = try #require(URL(string: "https://elsewhere.example.org/v1/graph/x"))
            await #expect(throws: PushError.unknownAddress) {
                _ = try await controller.issueAddress(rig.account, joining: garbage)
            }
            #expect(await rig.relay.requestCount == before)
            #expect(method.joined.withLock { $0 } == 0)
        }
    }

    @Test func pasteNotOursKeepsTheAddressInUse() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            let url = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            let garbage = try #require(URL(string: "https://elsewhere.example.org/x"))
            await #expect(throws: PushError.unknownAddress) {
                _ = try await controller.issueAddress(rig.account, joining: garbage)
            }
            #expect(await controller.isEnabled(rig.account.id))
            #expect(await controller.address(for: rig.account.id) == url)
        }
    }

    @Test func checkSwitchesOverFromAnotherMethod() async throws {
        let method = try StandInAddressed()
        let automatic = StandInAutomatic()
        try await withAddressed(method, also: [automatic]) { controller, rig in
            try await controller.enable(rig.account)
            #expect(rig.registry.registration(for: rig.account.id)?.method == automatic.kind)
            let url = try await controller.issueAddress(rig.account, joining: nil)
            #expect(await !controller.isAddressActive(rig.account.id))
            try await controller.enable(rig.account)
            let registration = try #require(rig.registry.registration(for: rig.account.id))
            #expect(registration.method == method.kind)
            #expect(registration.address == url)
            #expect(await controller.isAddressActive(rig.account.id))
            #expect(automatic.removed.withLock { $0 } == 1)
            #expect(rig.registry.registrations().count == 1)
            #expect(await rig.relay.subscriptions.count == 1)
        }
    }

    @Test func failedCheckKeepsTheOtherMethod() async throws {
        let method = try StandInAddressed()
        method.checkFails.withLock { $0 = .notSetUp }
        let automatic = StandInAutomatic()
        try await withAddressed(method, also: [automatic]) { controller, rig in
            try await controller.enable(rig.account)
            _ = try await controller.issueAddress(rig.account, joining: nil)
            await #expect(throws: PushError.notSetUp) {
                try await controller.enable(rig.account)
            }
            #expect(rig.registry.registration(for: rig.account.id)?.method == automatic.kind)
            #expect(automatic.removed.withLock { $0 } == 0)
        }
    }

    @Test func disableEndsAnIssuedAddress() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.disable(rig.account.id)
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(method.removed.withLock { $0 } == [method.address.handle])
        }
    }

    @Test func droppedAddressIsNoted() async throws {
        let method = try StandInAddressed()
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            try await controller.enable(rig.account)
            #expect(await !controller.addressDropped(rig.account.id))
            method.renewal.withLock { $0 = .gone }
            await controller.renewAll()
            #expect(await controller.addressDropped(rig.account.id))
            method.renewal.withLock { $0 = .kept }
            _ = try await controller.issueAddress(rig.account, joining: nil)
            #expect(await !controller.addressDropped(rig.account.id))
        }
    }

    @Test func issuedWhoseSubscriptionIsGoneIsDropped() async throws {
        let method = try StandInAddressed()
        method.checkFails.withLock { $0 = .http(404) }
        try await withAddressed(method) { controller, rig in
            _ = try await controller.issueAddress(rig.account, joining: nil)
            await #expect(throws: PushError.unknownAddress) {
                try await controller.enable(rig.account)
            }
            #expect(await controller.address(for: rig.account.id) == nil)
            #expect(await controller.addressDropped(rig.account.id))
        }
    }
}
