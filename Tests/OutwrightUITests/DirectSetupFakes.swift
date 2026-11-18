// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightSetup
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

/// Two devices over an in-memory link: the receiver listens, the sender's connect reaches it.
final class FakeLink: Sendable {
    struct State {
        var waiter: CheckedContinuation<(any SetupStream)?, Never>?
        var connects = 0
    }

    private let state = Mutex(State())

    var connects: Int { state.withLock { $0.connects } }
    /// Whether a receiver is listening.
    var isWaiting: Bool { state.withLock { $0.waiter != nil } }

    /// The receiver's listen: listening at once, then the one connection that comes within the time.
    var listen: ReceiveSetupModel.Listen {
        { [self] _ throws(SetupError) in { [self] within throws(SetupError) in try await accept(within: within) } }
    }

    var connect: SendSetupModel.Connect {
        { [self] _ throws(SetupError) in try await connectStream() }
    }

    func accept(within: Duration) async throws(SetupError) -> any SetupStream {
        let timer = Task { [self] in
            try? await Task.sleep(for: within)
            _ = deliver(nil)
        }
        defer { timer.cancel() }
        let stream = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(any SetupStream)?, Never>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.waiter = continuation
                    return false
                }
                if cancelled { continuation.resume(returning: nil) }
            }
        } onCancel: {
            _ = deliver(nil)
        }
        guard let stream else { throw .timedOut }
        return stream
    }

    /// Hands `stream` to the receiver waiting in accept; false when none is.
    func deliver(_ stream: (any SetupStream)?) -> Bool {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: stream)
        return waiter != nil
    }

    /// A new pair: one end to the receiver once it waits (for as long as the tests' short timeout, so a
    /// receiver slow to start under a full test run is still met), the other returned.
    func connectStream() async throws(SetupError) -> any SetupStream {
        state.withLock { $0.connects += 1 }
        let (mine, theirs) = SetupStreamPair.make()
        let deadline = ContinuousClock.now + DirectSetupModelTests.short
        while ContinuousClock.now < deadline {
            if deliver(theirs) { return mine }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw .timedOut
    }
}

/// A stream that lets `limit` octets through, then cuts the link.
final class CuttingStream: SetupStream {
    private let inner: any SetupStream
    private let left: Mutex<Int>

    init(_ inner: any SetupStream, limit: Int) {
        self.inner = inner
        left = Mutex(limit)
    }

    func send(_ data: Data) async throws(SetupError) {
        let allowed = left.withLock { left in
            defer { left -= min(left, data.count) }
            return min(left, data.count)
        }
        if allowed > 0 { try await inner.send(data.prefix(allowed)) }
        if allowed < data.count {
            inner.close()
            throw .connectionLost
        }
    }

    func receive(exactly count: Int) async throws(SetupError) -> Data { try await inner.receive(exactly: count) }
    func close() { inner.close() }
}

/// How often each device's accounts part exported and imported.
final class Calls: Sendable {
    private let counts = Mutex((exports: 0, imports: 0))
    var exports: Int { counts.withLock { $0.exports } }
    var imports: Int { counts.withLock { $0.imports } }
    func exported() { counts.withLock { $0.exports += 1 } }
    func imported() { counts.withLock { $0.imports += 1 } }
}

/// Accounts carried as a list of addresses, added on import.
struct AccountsPart: SetupPart {
    let name = "accounts"
    let title = "Accounts"
    let version = 1
    let held: [String]
    let calls: Calls
    /// Padding for a bundle large enough to be cut in the middle.
    var padding = 0
    /// The export fails as a keychain that refuses does.
    var exportFails = false
    /// How long an import takes.
    var importTakes: Duration = .zero

    struct Content: Codable {
        var addresses: [String]
        var padding: String
    }

    func export() async throws(SetupError) -> Data {
        calls.exported()
        if exportFails { throw .unavailable }
        let content = Content(addresses: held, padding: String(repeating: "x", count: padding))
        return (try? JSONEncoder().encode(content)) ?? Data()
    }

    func summary(of content: Data) throws(SetupError) -> [SetupItem] {
        guard let content = try? JSONDecoder().decode(Content.self, from: content) else { throw .malformed }
        return content.addresses.map { SetupItem(kind: .account, label: $0) }
    }

    func items() async -> [SetupItem] { held.map { SetupItem(kind: .account, label: $0) } }

    func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        calls.imported()
        try? await Task.sleep(for: importTakes)
        return SetupImportReport(added: (try? summary(of: content)) ?? [])
    }
}

/// Something that waits until the test lets it go: an unlock, or the notifications ask.
final class Gate: DeviceUnlock {
    private let state = Mutex((asked: false, open: false))
    var asked: Bool { state.withLock { $0.asked } }
    func open() { state.withLock { $0.open = true } }

    func pass() async -> Bool {
        state.withLock { $0.asked = true }
        while !state.withLock({ $0.open }) { try? await Task.sleep(for: .milliseconds(5)) }
        return true
    }

    func unlock(reason: String) async -> Bool { await pass() }
}

@MainActor final class Count {
    var value = 0
}

func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension DirectSetupModelTests {
    /// The limit on every wait a passing test makes. A full test run keeps the main actor busy for
    /// many seconds at a time (hundreds of main-actor tests), and the models wait on it; nothing
    /// here waits this out.
    nonisolated static let short = Duration.seconds(60)
    static let addresses = ["pat@example.org", "lee@example.org"]
    static let items = addresses.map { SetupItem(kind: .account, label: $0) }

    func sender(
        _ link: FakeLink, calls: Calls = Calls(), unlocks: Bool = true, unlock: (any DeviceUnlock)? = nil,
        exportFails: Bool = false, timeout: Duration = short
    ) -> SendSetupModel {
        var part = AccountsPart(held: Self.addresses, calls: calls)
        part.exportFails = exportFails
        return SendSetupModel(
            exchange: SetupExchange(parts: [part], device: "Pat's phone", parameters: SetupModelTests.quick),
            unlock: unlock ?? SetupModelTests.FakeUnlock(answer: unlocks), connect: link.connect,
            handshakeTimeout: Self.short, timeout: timeout)
    }

    func receiver(
        _ link: FakeLink, calls: Calls = Calls(), restored: Count = Count(), codeLife: Duration = short,
        handshakeTimeout: Duration = short, importTakes: Duration = .zero, notices: SetupNotices = .none,
        phoneContacts: SetupPhoneContacts = .none, listen: ReceiveSetupModel.Listen? = nil
    ) -> ReceiveSetupModel {
        var part = AccountsPart(held: [], calls: calls)
        part.importTakes = importTakes
        let setup = SetupModel(
            exchange: SetupExchange(parts: [part], device: "Pat's iPad", parameters: SetupModelTests.quick),
            unlock: SetupModelTests.FakeUnlock(answer: true), notices: notices, phoneContacts: phoneContacts)
        return ReceiveSetupModel(
            setup: setup, device: "Pat's iPad", listen: listen ?? link.listen, restored: { restored.value += 1 },
            codeLife: codeLife, handshakeTimeout: handshakeTimeout, timeout: Self.short)
    }

    func shownCode(of model: ReceiveSetupModel) -> PairingCode? {
        if case .showing(let code, _) = model.state { return code }
        return nil
    }

    /// The test as the sending device: connects to the receiver showing `code`, handshakes and reads its name.
    /// Off the main actor, so a busy one never holds it past its partner's time.
    nonisolated func sendingDevice(_ link: FakeLink, code: PairingCode) async throws -> SetupChannel {
        let channel = try await SetupTransfer.connect(
            try await link.connectStream(), code: code, asInitiator: true, handshakeTimeout: Self.short,
            timeout: Self.short)
        _ = try await channel.receiveHello()
        return channel
    }

    /// The test as the receiving device: takes the connection, handshakes and says its name. Off the
    /// main actor, so a busy one never holds it past its partner's time.
    nonisolated func receivingDevice(
        _ link: FakeLink, code: PairingCode, name: String
    ) async throws -> SetupChannel {
        let stream = try await link.accept(within: Self.short)
        let channel = try await SetupTransfer.connect(
            stream, code: code, asInitiator: false, handshakeTimeout: Self.short, timeout: Self.short)
        try await channel.sendHello(device: name)
        return channel
    }

    /// The test as the receiving device, after the hello: takes the bundle and says it was restored.
    /// Off the main actor, so the answer goes within a sender's short wait however busy that is.
    nonisolated func answer(_ channel: SetupChannel) async throws {
        _ = try await channel.receiveBundle()
        try await channel.sendDone(restored: true)
    }
}
