// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightSetup

@Suite struct SetupTransferTests {
    /// Two connected channels: the device that shows the code sends, the one that scans it receives.
    struct Session {
        let sender: SetupChannel
        let receiver: SetupChannel
        let senderEnd: SetupStreamPair.End
        let receiverEnd: SetupStreamPair.End
    }

    /// A link that takes its time over a large write, as a network does, so a small write after it could overtake it.
    struct SlowLink: SetupStream {
        let end: SetupStreamPair.End
        func send(_ data: Data) async throws(SetupError) {
            if data.count > 10_000 { try? await Task.sleep(for: .milliseconds(10)) }
            try await end.send(data)
        }
        func receive(exactly count: Int) async throws(SetupError) -> Data { try await end.receive(exactly: count) }
        func close() { end.close() }
    }

    static func connected(timeout: Duration = .seconds(300), slowSender: Bool = false) async throws -> Session {
        let code = PairingCode.generate(role: .sends, device: "Old phone")
        let (senderEnd, receiverEnd) = SetupStreamPair.make()
        let senderLink: any SetupStream = slowSender ? SlowLink(end: senderEnd) : senderEnd
        async let sender = SetupTransfer.connect(
            senderLink, code: code, asInitiator: false, timeout: timeout)
        async let receiver = SetupTransfer.connect(
            receiverEnd, code: code, asInitiator: true, timeout: timeout)
        return Session(
            sender: try await sender, receiver: try await receiver, senderEnd: senderEnd, receiverEnd: receiverEnd)
    }

    static func outcome(_ body: () async throws(SetupError) -> SetupChannel) async -> SetupError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    static func header(_ type: UInt8, _ length: Int) -> [UInt8] {
        [type] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }
    }

    static let bundle = SetupBundle(
        created: Date(timeIntervalSince1970: 1_800_000_000), device: "Old phone",
        parts: [
            "accounts": .init(version: 1, title: "Accounts", content: Data("[{\"host\":\"mail.example.org\"}]".utf8)),
            // Larger than one transport message, so the record is split.
            "large": .init(version: 1, content: Data(repeating: 0x41, count: 200_000))
        ])

    @Test func transferHappyPath() async throws {
        let session = try await Self.connected()
        try await session.receiver.sendHello(device: "New phone")
        #expect(try await session.sender.receiveHello() == "New phone")
        try await session.sender.sendBundle(Self.bundle)
        #expect(try await session.receiver.receiveBundle() == Self.bundle)
        try await session.receiver.sendDone(restored: true)
        #expect(try await session.sender.receiveDone() == true)
    }

    @Test func aDeviceNameWithAnEmojiNeverBreaksPairing() async throws {
        // A family emoji joined by ZWJ (a format character) and a right-to-left mark.
        let shown = PairingCode.generate(role: .sends, device: "Anna\u{200F} 👨\u{200D}👩\u{200D}👧")
        let scanned = try PairingCode(text: shown.text)
        #expect(scanned.device == "Anna 👨👩👧")
        let (showerEnd, scannerEnd) = SetupStreamPair.make()
        async let shower = Self.outcome { () async throws(SetupError) in
            try await SetupTransfer.connect(showerEnd, code: shown, asInitiator: false)
        }
        async let scanner = Self.outcome { () async throws(SetupError) in
            try await SetupTransfer.connect(scannerEnd, code: scanned, asInitiator: true)
        }
        #expect(await shower == nil)
        #expect(await scanner == nil)
    }

    @Test func wrongCodeEndsTheSession() async {
        let code = PairingCode.generate(role: .sends, device: "Old phone")
        var scanned = code
        scanned.secret = PairingCode.generate(role: .sends, device: "Old phone").secret
        let (shower, scanner) = SetupStreamPair.make()
        async let showerOutcome = Self.outcome { () async throws(SetupError) in
            try await SetupTransfer.connect(shower, code: code, asInitiator: false)
        }
        async let scannerOutcome = Self.outcome { () async throws(SetupError) in
            try await SetupTransfer.connect(scanner, code: scanned, asInitiator: true)
        }
        #expect(await showerOutcome == .handshakeFailed)
        #expect(await scannerOutcome == .handshakeFailed)
    }

    @Test func stopReachesTheOtherSide() async throws {
        let session = try await Self.connected()
        try await session.receiver.sendHello(device: "New phone")
        _ = try await session.sender.receiveHello()
        try await session.sender.sendStop()
        await #expect(throws: SetupError.stopped) { try await session.receiver.receiveBundle() }
    }

    /// The sender waits for `done` from the confirmation on, so the receiver leaving shows at once; that wait is
    /// timed only once the bundle went.
    @Test func doneIsWaitedForUntimedUntilTheBundleGoes() async throws {
        let session = try await Self.connected(timeout: .milliseconds(200))
        async let done = session.sender.receiveDone()
        try await Task.sleep(for: .milliseconds(500))
        try await session.sender.sendBundle(Self.bundle)
        #expect(try await session.receiver.receiveBundle() == Self.bundle)
        try await session.receiver.sendDone(restored: true)
        #expect(try await done == true)
    }

    @Test func doneIsTimedOnceTheBundleWent() async throws {
        let session = try await Self.connected(timeout: .milliseconds(200))
        async let done = Self.outcome { () async throws(SetupError) in
            _ = try await session.sender.receiveDone()
            return session.sender
        }
        try await session.sender.sendBundle(Self.bundle)
        #expect(await done == .timedOut)
    }

    @Test func aStopEndsTheWaitForDone() async throws {
        let session = try await Self.connected()
        async let done = Self.outcome { () async throws(SetupError) in
            _ = try await session.sender.receiveDone()
            return session.sender
        }
        try await Task.sleep(for: .milliseconds(50))
        try await session.receiver.sendStop()
        #expect(await done == .stopped)
    }

    /// The receiver holding the bundle while its owner decides hears the sender leave.
    @Test func untilLeftEndsOnAStop() async throws {
        let session = try await Self.connected()
        async let left = session.receiver.untilLeft()
        try await Task.sleep(for: .milliseconds(50))
        try await session.sender.sendStop()
        #expect(await left == .stopped)
    }

    @Test func untilLeftEndsWhenThePeerCloses() async throws {
        let session = try await Self.connected()
        async let left = session.receiver.untilLeft()
        try await Task.sleep(for: .milliseconds(50))
        session.sender.close()
        #expect(await left == .connectionLost)
    }

    /// A record while nothing is expected is out of order: the session ends.
    @Test func untilLeftEndsOnAnyOtherRecord() async throws {
        let session = try await Self.connected()
        async let left = session.receiver.untilLeft()
        try await Task.sleep(for: .milliseconds(50))
        try await session.sender.sendDone(restored: true)
        #expect(await left == .malformed)
        await #expect(throws: SetupError.malformed) { try await session.receiver.sendDone(restored: true) }
    }

    /// A bundle of a newer version is refused, and the session stays up for the receiver to say so with a stop.
    @Test func aNewerBundleLeavesRoomForAStop() async throws {
        let session = try await Self.connected()
        var newer = Self.bundle
        newer.version = SetupBundle.currentVersion + 1
        try await session.sender.sendBundle(newer)
        await #expect(throws: SetupError.unsupported) { try await session.receiver.receiveBundle() }
        try await session.receiver.sendStop()
        await #expect(throws: SetupError.stopped) { try await session.sender.receiveDone() }
    }

    @Test func helloNameIsCleaned() async throws {
        let session = try await Self.connected()
        try await session.receiver.sendHello(device: "New\u{202E}enohp\u{0007}")
        #expect(try await session.sender.receiveHello() == "Newenohp")

        let empty = try await Self.connected()
        try await empty.receiver.sendHello(device: "\u{200B}\u{0000}\u{202D}")
        #expect(try await empty.sender.receiveHello() == "")
    }

    @Test func aStopRacingABundleArrivesAfterIt() async throws {
        let big = SetupBundle(
            created: Self.bundle.created, device: "Old phone",
            parts: ["large": .init(version: 1, content: Data(repeating: 0x42, count: 2_000_000))])
        for _ in 0..<20 {
            let session = try await Self.connected(slowSender: true)
            // The bundle is queued first; the stop follows while its slow write is under way.
            let sending = Task { try await session.sender.sendBundle(big) }
            try await Task.sleep(for: .milliseconds(5))
            try await session.sender.sendStop()
            #expect(try await session.receiver.receiveBundle() == big)
            await #expect(throws: SetupError.stopped) { try await session.receiver.receiveBundle() }
            try await sending.value
        }
    }

    @Test func aCancelledSendEndsTheSession() async throws {
        let session = try await Self.connected(timeout: .seconds(2))
        session.receiverEnd.stopReading()
        let sending = Task { try await session.sender.sendBundle(Self.bundle) }
        sending.cancel()
        let result = await sending.result
        #expect(throws: SetupError.connectionLost) { try result.get() }
        await #expect(throws: SetupError.connectionLost) { try await session.sender.sendStop() }
    }

    @Test func aSecondConcurrentReceiveIsRefused() async throws {
        let session = try await Self.connected(timeout: .milliseconds(300))
        async let first = Self.received { () async throws(SetupError) in try await session.receiver.receiveHello() }
        async let second = Self.received { () async throws(SetupError) in try await session.receiver.receiveHello() }
        let outcomes = await [first, second]
        #expect(outcomes.contains(.malformed))
        #expect(outcomes.contains(.timedOut))
    }

    static func received(_ body: () async throws(SetupError) -> String) async -> SetupError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    @Test func aSendToAPeerThatStopsReadingTimesOut() async throws {
        let session = try await Self.connected(timeout: .milliseconds(50))
        session.receiverEnd.stopReading()
        await #expect(throws: SetupError.timedOut) { try await session.sender.sendBundle(Self.bundle) }
        await #expect(throws: SetupError.timedOut) { try await session.sender.sendStop() }
    }

    @Test func oversizeRecordIsRefusedBeforeBuffering() async throws {
        let session = try await Self.connected()
        let before = session.receiverEnd.bytesRead
        try await session.sender.send(messages: [
            Self.header(2, SymmetricMessage.maximumSize + 1), [UInt8](repeating: 0, count: 1000)
        ])
        await #expect(throws: SetupError.malformed) { try await session.receiver.receiveBundle() }
        // The frame's length, the five octets of the header and the tag: nothing of the payload.
        #expect(session.receiverEnd.bytesRead == before + 2 + 5 + 16)
    }

    @Test func unknownRecordTypeIsRefused() async throws {
        for header in [Self.header(9, 0), Self.header(0, 0), Self.header(4, 1)] {
            let session = try await Self.connected()
            try await session.sender.send(messages: [header])
            await #expect(throws: SetupError.malformed) { try await session.receiver.receiveBundle() }
        }
    }

    @Test func aRecordOfTheWrongTypeIsRefused() async throws {
        let session = try await Self.connected()
        try await session.sender.sendDone(restored: true)
        await #expect(throws: SetupError.malformed) { try await session.receiver.receiveBundle() }
    }

    @Test func cutStreamFails() async throws {
        let session = try await Self.connected()
        try await session.sender.send(messages: [Self.header(2, 1000), [UInt8](repeating: 0x7B, count: 100)])
        session.senderEnd.close()
        await #expect(throws: SetupError.connectionLost) { try await session.receiver.receiveBundle() }
    }

    @Test func receiveTimesOut() async throws {
        let session = try await Self.connected(timeout: .milliseconds(50))
        await #expect(throws: SetupError.timedOut) { try await session.receiver.receiveBundle() }

        let (lonely, _) = SetupStreamPair.make()
        let code = PairingCode.generate(role: .sends, device: "x")
        let handshake = await Self.outcome { () async throws(SetupError) in
            try await SetupTransfer.connect(
                lonely, code: code, asInitiator: true, handshakeTimeout: .milliseconds(50))
        }
        #expect(handshake == .timedOut)
    }

    @Test func recordsReadArbitraryBytesWithoutCrashing() async throws {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<200 {
            let session = try await Self.connected()
            if round.isMultiple(of: 2) {
                // Raw bytes on the wire: frames that do not open.
                let junk = (0..<Int.random(in: 0..<400, using: &generator)).map { _ in
                    UInt8.random(in: 0...255, using: &generator)
                }
                try await session.senderEnd.send(Data(junk))
            } else {
                // Messages that open, with arbitrary records in them.
                var messages: [[UInt8]] = []
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    if Bool.random(using: &generator) {
                        let type = UInt8.random(in: 0...5, using: &generator)
                        messages.append(Self.header(type, Int.random(in: 0...300, using: &generator)))
                    } else {
                        messages.append(
                            (0..<Int.random(in: 0..<300, using: &generator)).map { _ in
                                UInt8.random(in: 0...255, using: &generator)
                            })
                    }
                }
                try await session.sender.send(messages: messages)
            }
            session.senderEnd.close()
            do {
                switch round % 3 {
                case 0: _ = try await session.receiver.receiveBundle()
                case 1: _ = try await session.receiver.receiveHello()
                default: _ = try await session.receiver.receiveDone()
                }
            } catch {
                _ = error as SetupError
            }
        }
    }
}
