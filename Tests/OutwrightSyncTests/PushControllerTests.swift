// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightNet
import OutwrightPush
import OutwrightSync
import Synchronization
import Testing

/// Accepts everything: the fake relay takes any non-empty attestation and assertion. Its key
/// id is `key-1` until forgotten, then `key-2`, and so on.
private final class StubAttester: DeviceAttester {
    private let generation = Mutex(1)
    func keyID() async throws(PushError) -> String { "key-\(generation.withLock { $0 })" }
    func forgetKey() async { generation.withLock { $0 += 1 } }
    func attest(keyID: String, challenge: String) async throws(PushError) -> Data { Data("attested".utf8) }
    func assert(keyID: String, challenge: String) async throws(PushError) -> Data { Data("asserted".utf8) }
}

private final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private struct PushRig {
    let h: Harness
    let relay: FakeRelay
    let jmap: FakeJMAPServer
    let registry: PushRegistry
    let registryFile: URL
    let clock: TestClock
    let controller: PushController
    /// Another controller over the same relay, registry and keychain: the app after a relaunch,
    /// before APNs has handed it this launch's token.
    let relaunched: @Sendable () -> PushController

    /// Another account on the same servers, with its password in the keychain.
    func another() throws -> Account {
        var account = h.account
        account.id = AccountID()
        try h.secrets.setPassword(Secret(FakeIMAPServer.password), for: account.id)
        return account
    }
}

/// A folder of its own for one rig's files, removed when the rig is done.
private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-push-\(UUID().uuidString)", isDirectory: true)
}

/// Starts the relay and JMAP fakes beside the IMAP harness. With `verify`, a mail server stand-in
/// answers every new JMAP subscription with its `PushVerification`, as Stalwart does.
private func withPush(
    verify: Bool = true, verifyWithin: Duration = .seconds(10), _ body: (PushRig) async throws -> Void
) async throws {
    try await withHarness { h in
        let relay = FakeRelay()
        let jmap = FakeJMAPServer(user: FakeIMAPServer.user, password: FakeIMAPServer.password)
        let base = try await relay.start()
        let host = try await jmap.start()
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("push-registry.json")
        let registry = PushRegistry(fileURL: file, vault: InMemoryPushVault())
        let clock = TestClock()
        let attester = StubAttester()
        let marks = folder.appendingPathComponent("push-watermarks.json")
        let secrets = h.secrets
        let make: @Sendable () -> PushController = {
            PushController(
                relay: RelayClient(base: base), attester: attester, registry: registry, credentials: CredentialProvider(secrets: secrets),
                marks: PushWatermarks(fileURL: marks), environment: .development,
                methods: [JMAPPushMethod(secrets: secrets, jmapHost: { _ in host })],
                timing: PushTiming(
                    poll: .milliseconds(20), verifyWithin: verifyWithin, backoffs: [.zero, .zero, .zero]),
                now: { clock.now })
        }
        let controller = make()
        let verifier = Task {
            var sent: Set<String> = []
            while verify, !Task.isCancelled {
                for (id, sub) in await jmap.subscriptions where !sub.verified && !sent.contains(id) {
                    sent.insert(id)
                    await jmap.sendVerification(id, to: relay)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let rig = PushRig(
            h: h, relay: relay, jmap: jmap, registry: registry, registryFile: file, clock: clock,
            controller: controller, relaunched: make)
        do {
            try await body(rig)
        } catch {
            verifier.cancel()
            await relay.stop()
            await jmap.stop()
            throw error
        }
        verifier.cancel()
        await relay.stop()
        await jmap.stop()
    }
}

private let token = Data([0xAB, 0xCD, 0x01])

@Suite struct PushControllerTests {
    @Test func enableVerifiesAndActivates() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            #expect(await rig.controller.isEnabled(rig.h.account.id))
            let registration = try #require(rig.registry.registration(for: rig.h.account.id))
            #expect(rig.registry.registration(subscriptionID: registration.relay.id)?.account.id == rig.h.account.id)
            #expect(try rig.registry.keys(subscriptionID: registration.relay.id) != nil)
            let sub = try #require(await rig.jmap.subscriptions[registration.handle])
            #expect(sub.verified)
            #expect(sub.url == registration.relay.pushURL.absoluteString)
            #expect(await rig.relay.subscriptions == [registration.relay.id])
            // Active: a body the mail server sends now is no longer held as pending.
            await rig.jmap.deliverEmail(registration.handle, to: rig.relay)
            #expect(await rig.relay.held.isEmpty)
        }
    }

    /// Where a push's mail starts is the store's business, on the first push: switching on asks
    /// the mailbox nothing.
    @Test func enableDoesNotSignInToTheMailbox() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            #expect(await rig.controller.isEnabled(rig.h.account.id))
            #expect(await rig.h.imap.sessionStarts.isEmpty)
        }
    }

    @Test func theExtensionSeesTheAccountAsItWasLastChanged() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            let before = try #require(rig.registry.registration(for: rig.h.account.id))
            var renamed = rig.h.account
            renamed.displayName = "Anna Lind"
            renamed.imap = MailEndpoint(host: "imap.example.org", port: 993, security: "tls")
            await rig.controller.accountChanged(renamed)
            let after = try #require(rig.registry.registration(subscriptionID: before.relay.id))
            #expect(after.account.displayName == "Anna Lind")
            #expect(after.account.imap.host == "imap.example.org")
            #expect(after.handle == before.handle)
            var other = renamed
            other.id = AccountID(raw: UUID())
            other.displayName = "Someone else"
            await rig.controller.accountChanged(other)
            #expect(rig.registry.registrations().map(\.account.displayName) == ["Anna Lind"])
        }
    }

    @Test func enableTimesOutWithoutVerificationAndCleansUp() async throws {
        try await withPush(verify: false, verifyWithin: .milliseconds(300)) { rig in
            await rig.controller.setDeviceToken(token)
            await #expect(throws: PushError.timeout) { try await rig.controller.enable(rig.h.account) }
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await rig.jmap.subscriptions.isEmpty)
            #expect(await !rig.controller.isEnabled(rig.h.account.id))
            #expect(rig.registry.registration(for: rig.h.account.id) == nil)
        }
    }

    @Test func enableWithoutDeviceTokenFails() async throws {
        try await withPush { rig in
            await #expect(throws: PushError.noDeviceToken) { try await rig.controller.enable(rig.h.account) }
            #expect(await rig.relay.subscriptions.isEmpty)
        }
    }

    @Test func rateLimitedEnableBacksOffAndRetries() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            await rig.relay.refuseNext(2, with: .json(429, "{\"error\":\"rate_limited\"}"))
            try await rig.controller.enable(rig.h.account)
            #expect(await rig.controller.isEnabled(rig.h.account.id))
        }
    }

    @Test func disableDestroysBoth() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            let registration = try #require(rig.registry.registration(for: rig.h.account.id))
            try await rig.controller.disable(rig.h.account.id)
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await rig.jmap.subscriptions.isEmpty)
            #expect(await !rig.controller.isEnabled(rig.h.account.id))
            #expect(try rig.registry.keys(subscriptionID: registration.relay.id) == nil)
        }
    }

    @Test func tokenChangeUpdatesRelay() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            #expect(await Array(rig.relay.tokens.values) == ["abcd01"])
            await rig.controller.setDeviceToken(Data([0x01, 0x02]))
            #expect(await Array(rig.relay.tokens.values) == ["0102"])
        }
    }

    @Test func eleventhAccountIsLimit() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            for _ in 0..<10 {
                try await rig.controller.enable(try rig.another())
            }
            let eleventh = try rig.another()
            await #expect(throws: PushError.limit) { try await rig.controller.enable(eleventh) }
            #expect(await !rig.controller.isEnabled(eleventh.id))
            #expect(await rig.relay.subscriptions.count == 10)
            #expect(await rig.jmap.subscriptions.count == 10)
        }
    }

    @Test func renewExtendsExpiry() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            let registration = try #require(rig.registry.registration(for: rig.h.account.id))
            rig.clock.advance(3 * 86_400)
            await rig.controller.renewAll()
            let expected = rig.clock.now.addingTimeInterval(7 * 86_400).formatted(.iso8601)
            #expect(await rig.jmap.subscriptions[registration.handle]?.expires == expected)
        }
    }

    @Test func keysNeverWrittenToRegistryFile() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            let registration = try #require(rig.registry.registration(for: rig.h.account.id))
            let keys = try #require(try rig.registry.keys(subscriptionID: registration.relay.id))
            let file = try Data(contentsOf: rig.registryFile)
            let raw = keys.rawRepresentation
            let privateKey = raw.prefix(32)
            for secret in [raw, privateKey, Data(raw.base64EncodedString().utf8),
                           Data(privateKey.base64EncodedString().utf8), Data("secret".utf8)] {
                #expect(file.range(of: secret) == nil)
            }
        }
    }

    @Test func forgottenDeviceIsRegisteredAgain() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            let second = try rig.another()
            try await rig.controller.enable(second)
            #expect(await rig.controller.isEnabled(second.id))
            #expect(await rig.relay.subscriptions.count == 1)
        }
    }

    @Test func tokenRefusedForUnknownDeviceRegistersOnNextEnable() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.controller.setDeviceToken(Data([0x01, 0x02]))
            try await rig.controller.enable(try rig.another())
            #expect(await Array(rig.relay.tokens.values) == ["0102"])
        }
    }

    @Test func forgottenDeviceIsRegisteredWithAFreshKey() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            try await rig.controller.enable(try rig.another())
            #expect(await rig.relay.registeredKeys == ["key-1", "key-2"])
        }
    }

    @Test func renewRestoresPushTheRelayForgot() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            let second = try rig.another()
            try await rig.controller.enable(rig.h.account)
            try await rig.controller.enable(second)
            await rig.relay.forgetDevices()
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id, second.id])
            #expect(await rig.relay.registeredKeys == ["key-1", "key-2"])
        }
    }

    @Test func renewRestoresPushAfterTheTokenFoundTheDeviceGone() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.controller.setDeviceToken(Data([0x01, 0x02]))
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id])
            #expect(await Array(rig.relay.tokens.values) == ["0102"])
        }
    }

    @Test func renewReplacesASubscriptionTheRelayLost() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            let second = try rig.another()
            try await rig.controller.enable(rig.h.account)
            try await rig.controller.enable(second)
            let lost = try #require(rig.registry.registration(for: second.id))
            await rig.relay.forgetSubscription(lost.relay.id)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id, second.id])
            #expect(rig.registry.registration(for: second.id)?.relay.id != lost.relay.id)
        }
    }

    @Test func renewSwitchesOffWhatCannotBeRestored() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            let second = try rig.another()
            try await rig.controller.enable(rig.h.account)
            try await rig.controller.enable(second)
            let stranded = try #require(rig.registry.registration(for: second.id)).handle
            await rig.relay.forgetDevices()
            // Without its password the account can neither be switched on again nor reach its
            // mail server, whose subscription lapses at its expiry.
            try rig.h.secrets.remove(for: second.id)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id], unreachable: [stranded])
            #expect(await !rig.controller.isEnabled(second.id))
        }
    }

    @Test func transientFailureWhileRestoringKeepsPushOnUntilTheNextRenew() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.relay.refuse("POST", "devices", with: .json(503, "{\"error\":\"unavailable\"}"))
            await rig.controller.renewAll()
            #expect(await rig.controller.isEnabled(rig.h.account.id))
            await rig.relay.refuse("POST", "devices", with: nil)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id])
        }
    }

    @Test func mailServerOutageWhileRestoringKeepsPushOn() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.jmap.forceSession(FakeHTTPResponse(status: 503))
            await rig.controller.renewAll()
            #expect(await rig.controller.isEnabled(rig.h.account.id))
            await rig.jmap.forceSession(nil)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id])
        }
    }

    @Test func cancelledRestoreKeepsPushOn() async throws {
        try await withPush(verify: false) { rig in
            await rig.controller.setDeviceToken(token)
            let account = rig.h.account
            let controller = rig.controller
            let enabling = Task { try await controller.enable(account) }
            #expect(await eventually { await !rig.jmap.subscriptions.isEmpty })
            let first = try #require(await rig.jmap.subscriptions.keys.first)
            await rig.jmap.sendVerification(first, to: rig.relay)
            try await enabling.value
            await rig.relay.forgetDevices()
            // The restore waits for a verification that never comes, until it is cancelled.
            let renewing = Task { await controller.renewAll() }
            #expect(await eventually { await rig.jmap.subscriptions.keys.contains { $0 != first } })
            renewing.cancel()
            await renewing.value
            #expect(await controller.isEnabled(account.id))
        }
    }

    @Test(arguments: [429, 408])
    func busyMailServerWhileRestoringKeepsPushOn(status: Int) async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.jmap.forceSession(FakeHTTPResponse(status: status))
            await rig.controller.renewAll()
            #expect(await rig.controller.isEnabled(rig.h.account.id))
            await rig.jmap.forceSession(nil)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id])
        }
    }

    @Test func refusalWhileRestoringSwitchesPushOff() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            await rig.relay.refuse("POST", "subscriptions", with: .json(409, "{\"error\":\"limit\"}"))
            await rig.controller.renewAll()
            #expect(await !rig.controller.isEnabled(rig.h.account.id))
            #expect(await rig.jmap.subscriptions.isEmpty)
        }
    }

    @Test func renewReplacesASubscriptionTheMailServerLost() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            let second = try rig.another()
            try await rig.controller.enable(rig.h.account)
            try await rig.controller.enable(second)
            let lost = try #require(rig.registry.registration(for: second.id))
            await rig.jmap.forget(lost.handle)
            await rig.controller.renewAll()
            try await expectActive(rig, [rig.h.account.id, second.id])
            #expect(rig.registry.registration(for: second.id)?.handle != lost.handle)
        }
    }

    @Test func noRestoreBeforeThisLaunchHasAToken() async throws {
        try await withPush { rig in
            await rig.controller.setDeviceToken(token)
            try await rig.controller.enable(rig.h.account)
            await rig.relay.forgetDevices()
            let relaunched = rig.relaunched()
            await relaunched.renewAll()
            // The stored token may be the one APNs just refused: nothing is made with it.
            #expect(await rig.relay.registeredKeys == ["key-1"])
            #expect(await relaunched.isEnabled(rig.h.account.id))
            await relaunched.setDeviceToken(Data([0x01, 0x02]))
            await relaunched.renewAll()
            try await expectActive(rig, [rig.h.account.id])
            #expect(await Array(rig.relay.tokens.values) == ["0102"])
        }
    }

    @Test func cancelledEnableStillCleansUp() async throws {
        try await withPush(verify: false, verifyWithin: .seconds(30)) { rig in
            await rig.controller.setDeviceToken(token)
            let account = rig.h.account
            let controller = rig.controller
            let task = Task { try await controller.enable(account) }
            #expect(await eventually { await !rig.jmap.subscriptions.isEmpty })
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await #expect(throws: PushError.self) { try await task.value }
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await rig.jmap.subscriptions.isEmpty)
            #expect(await !rig.controller.isEnabled(account.id))
        }
    }

    @Test func enableCancelledBeforeTheMailServerAnswersLeavesNothingThere() async throws {
        try await withPush(verify: false, verifyWithin: .seconds(30)) { rig in
            await rig.controller.setDeviceToken(token)
            // The subscription exists on the mail server before its answer reaches the phone.
            await rig.jmap.delayAPIAnswers(.milliseconds(500))
            let account = rig.h.account
            let controller = rig.controller
            let task = Task { try await controller.enable(account) }
            #expect(await eventually { await !rig.jmap.subscriptions.isEmpty })
            task.cancel()
            await #expect(throws: PushError.self) { try await task.value }
            #expect(await rig.jmap.subscriptions.isEmpty)
            #expect(await rig.relay.subscriptions.isEmpty)
            #expect(await !rig.controller.isEnabled(account.id))
        }
    }

    @Test func rateLimitWhilePollingDoesNotAbort() async throws {
        try await withPush(verify: false) { rig in
            await rig.controller.setDeviceToken(token)
            let account = rig.h.account
            let controller = rig.controller
            let task = Task { try await controller.enable(account) }
            #expect(await eventually { await !rig.jmap.subscriptions.isEmpty })
            // More refusals in a row than a relay call's backoff allows.
            await rig.relay.refuseNext(6, with: .json(429, "{\"error\":\"rate_limited\"}"))
            #expect(await eventually { await rig.relay.refusalsLeft == 0 })
            let id = try #require(await rig.jmap.subscriptions.keys.first)
            await rig.jmap.sendVerification(id, to: rig.relay)
            try await task.value
            #expect(await controller.isEnabled(account.id))
        }
    }
}

/// Push is on for exactly these accounts, and each one's subscriptions are live: active at the
/// relay and verified at the mail server, with nothing else left behind on either (but the
/// `unreachable` mail server subscriptions of an account whose password is gone).
private func expectActive(_ rig: PushRig, _ accounts: [AccountID], unreachable: Set<String> = []) async throws {
    let registrations = rig.registry.registrations()
    #expect(Set(registrations.map(\.account.id)) == Set(accounts))
    #expect(await rig.relay.subscriptions == Set(registrations.map(\.relay.id)))
    #expect(await Set(rig.jmap.subscriptions.keys).subtracting(unreachable) == Set(registrations.map(\.handle)))
    for registration in registrations {
        #expect(await rig.relay.isActive(registration.relay.id))
        #expect(await rig.jmap.subscriptions[registration.handle]?.verified == true)
    }
}

@Suite struct PushSupportTests {
    @Test func supportsPushWhenTheHostAnswersJMAP() async throws {
        try await withPush(verify: false) { rig in
            #expect(await rig.controller.offersPush(rig.h.account))
        }
    }

    @Test func noPushWhereNoJMAPAnswers() async throws {
        try await withHarness { h in
            let folder = scratchFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let controller = PushController(
                relay: RelayClient(base: try #require(URL(string: "http://127.0.0.1:1/v1"))),
                attester: StubAttester(),
                registry: PushRegistry(fileURL: folder.appendingPathComponent("push-registry.json"), vault: InMemoryPushVault()),
                credentials: CredentialProvider(secrets: h.secrets), marks: PushWatermarks(fileURL: folder.appendingPathComponent("push-watermarks.json")),
                environment: .development, methods: [JMAPPushMethod(secrets: h.secrets, jmapHost: { _ in "127.0.0.1:1" })])
            #expect(await !controller.offersPush(h.account))
        }
    }
}
