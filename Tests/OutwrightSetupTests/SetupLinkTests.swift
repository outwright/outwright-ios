// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightSetup

/// The network link over loopback: the listener is not advertised and the other end connects by port.
@Suite struct SetupLinkTests {
    struct Link {
        let listener: SetupListener
        let server: any SetupStream
        let client: any SetupStream
        let port: UInt16
    }

    static func linked() async throws -> Link {
        let listener = SetupListener(service: "0123456789ab", advertised: false)
        let port = try await listener.start()
        async let accepted = listener.accept(within: .seconds(10))
        let client = try await SetupConnector.connect(host: "127.0.0.1", port: port)
        return Link(listener: listener, server: try await accepted, client: client, port: port)
    }

    static func failure<Value>(_ body: () async throws(SetupError) -> Value) async -> SetupError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    /// `count` octets in chunks of uneven sizes, so a read never lines up with a write.
    static func receive(_ stream: any SetupStream, count: Int) async throws -> Data {
        var data = Data()
        let sizes = [1, 4093, 65_537, 17, 30_000]
        var turn = 0
        while data.count < count {
            let size = min(sizes[turn % sizes.count], count - data.count)
            data.append(try await stream.receive(exactly: size))
            turn += 1
        }
        return data
    }

    static func pattern(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed })
    }

    @Test func bytesCrossTheLink() async throws {
        let link = try await Self.linked()
        defer {
            link.client.close()
            link.server.close()
        }
        let upward = Self.pattern(200 * 1024, seed: 0x5A)
        let downward = Self.pattern(200 * 1024, seed: 0xA5)
        async let sentUp: Void = {
            for start in stride(from: 0, to: upward.count, by: 50_000) {
                try await link.client.send(upward.subdata(in: start..<min(start + 50_000, upward.count)))
            }
        }()
        async let sentDown: Void = link.server.send(downward)
        async let receivedUp = Self.receive(link.server, count: upward.count)
        async let receivedDown = Self.receive(link.client, count: downward.count)
        try await sentUp
        try await sentDown
        #expect(try await receivedUp == upward)
        #expect(try await receivedDown == downward)
    }

    @Test func listenerAcceptsOnlyOneConnection() async throws {
        let link = try await Self.linked()
        defer {
            link.client.close()
            link.server.close()
        }
        // A second attempt is refused, or connected and then never served.
        if let second = try? await SetupConnector.connect(host: "127.0.0.1", port: link.port) {
            #expect(await Self.failure { () async throws(SetupError) in try await second.receive(exactly: 1) }
                == .connectionLost)
            second.close()
        }
        try await link.client.send(Data("ping".utf8))
        #expect(try await link.server.receive(exactly: 4) == Data("ping".utf8))
        try await link.server.send(Data("pong".utf8))
        #expect(try await link.client.receive(exactly: 4) == Data("pong".utf8))
    }

    @Test func listenerTimesOutWithoutAConnection() async throws {
        let listener = SetupListener(service: "0123456789ab", advertised: false)
        _ = try await listener.start()
        let error = await Self.failure { () async throws(SetupError) in
            try await listener.accept(within: .milliseconds(100))
        }
        #expect(error == .timedOut)
    }

    /// iOS ends a listening socket when the app is suspended: an accept waiting on it ends at once, not when the
    /// code runs out.
    @Test func aListenerTheSystemEndsEndsThePendingAccept() async throws {
        let listener = SetupListener(service: "0123456789ab", advertised: false)
        _ = try await listener.start()
        async let pending = Self.failure { () async throws(SetupError) in
            try await listener.accept(within: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        listener.underlying?.cancel()
        #expect(await pending == .connectionLost)
    }

    /// On iOS a listener can wait while the local network prompt is up and turn ready after it.
    @Test func aWaitingListenerIsWaitedFor() {
        #expect(SetupListener.startOutcome(of: .waiting(.posix(.ENETDOWN)), port: 0) == nil)
        #expect(SetupListener.startOutcome(of: .setup, port: 0) == nil)
        #expect(SetupListener.startOutcome(of: .ready, port: 4242) == .success(4242))
        #expect(SetupListener.startOutcome(of: .failed(.posix(.EADDRINUSE)), port: 0) == .failure(.connectionLost))
        #expect(SetupListener.startOutcome(of: .cancelled, port: 0) == .failure(.connectionLost))
    }

    @Test func aDeadlineEndsWhatDoesNotFinish() async {
        let error = await Self.failure { () async throws(SetupError) in
            try await SetupLink.deadline(.milliseconds(50)) { () async throws(SetupError) -> Int in
                try? await Task.sleep(for: .seconds(10))
                throw SetupError.connectionLost
            }
        }
        #expect(error == .timedOut)
    }

    @Test func closingOneSideEndsTheOther() async throws {
        let link = try await Self.linked()
        defer { link.server.close() }
        async let pending = Self.failure { () async throws(SetupError) in try await link.server.receive(exactly: 1) }
        try await Task.sleep(for: .milliseconds(20))
        link.client.close()
        #expect(await pending == .connectionLost)
    }

    @Test func closeEndsAPendingReceiveOnTheSameSide() async throws {
        let link = try await Self.linked()
        defer { link.server.close() }
        async let pending = Self.failure { () async throws(SetupError) in try await link.client.receive(exactly: 1) }
        try await Task.sleep(for: .milliseconds(20))
        link.client.close()
        #expect(await pending == .connectionLost)
    }

    /// The responder writes its refusal and closes right away; the scanner still reads the refusal.
    @Test func whatWasSentBeforeCloseStillArrives() async throws {
        let link = try await Self.linked()
        defer { link.client.close() }
        try await link.server.send(Data([0, 0]))
        link.server.close()
        #expect(try await link.client.receive(exactly: 2) == Data([0, 0]))
        #expect(await Self.failure { () async throws(SetupError) in try await link.client.receive(exactly: 1) }
            == .connectionLost)
    }

    /// Over the network too, the scanner of a wrong code reads the refusal and reports the code, not a lost link.
    @Test func aWrongCodeIsReportedOverTheLink() async throws {
        let link = try await Self.linked()
        defer {
            link.client.close()
            link.server.close()
        }
        let code = PairingCode.generate(role: .sends, device: "Old phone")
        var scanned = code
        scanned.secret = PairingCode.generate(role: .sends, device: "Old phone").secret
        async let shower = Self.failure { () async throws(SetupError) in
            try await SetupTransfer.connect(link.server, code: code, asInitiator: false)
        }
        async let scanner = Self.failure { () async throws(SetupError) in
            try await SetupTransfer.connect(link.client, code: scanned, asInitiator: true)
        }
        #expect(await shower == .handshakeFailed)
        #expect(await scanner == .handshakeFailed)
    }

    @Test func aReceiveAboveTheLargestFrameIsMalformed() async throws {
        let link = try await Self.linked()
        defer {
            link.client.close()
            link.server.close()
        }
        #expect(await Self.failure { () async throws(SetupError) in
            try await link.client.receive(exactly: SetupLink.maxReceive + 1)
        } == .malformed)
        #expect(await Self.failure { () async throws(SetupError) in try await link.client.receive(exactly: -1) }
            == .malformed)
    }

    @Test func aSendAfterCloseIsLost() async throws {
        let link = try await Self.linked()
        defer { link.server.close() }
        link.client.close()
        #expect(await Self.failure { () async throws(SetupError) in try await link.client.send(Data([1])) }
            == .connectionLost)
    }
}
