// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightSetup
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

@MainActor @Suite struct DirectSetupModelTests {
    @Test func sendAndReceiveEndToEnd() async throws {
        let link = FakeLink()
        let restored = Count()
        let receiver = receiver(link, restored: restored)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        #expect(code.role == .receives)
        #expect(code.device == "Pat's iPad")

        let sender = sender(link)
        await sender.scanned(code.text)
        #expect(sender.state == .confirm(device: "Pat's iPad", items: Self.items))
        #expect(await eventually { receiver.state == .waiting })

        await sender.send()
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(await eventually { if case .report = receiver.state { true } else { false } })
        guard case .report(let report) = receiver.state else { return }
        #expect(report.added == Self.items)
        #expect(restored.value == 1)
    }

    @Test func confirmShowsTheReceiversName() async throws {
        let link = FakeLink()
        let code = PairingCode.generate(role: .receives, device: "Name in the code")
        let sender = sender(link)
        async let channel = receivingDevice(link, code: code, name: "Lee's iPad")
        await sender.scanned(code.text)
        let held = try await channel
        defer { held.close() }
        #expect(sender.state == .confirm(device: "Lee's iPad", items: Self.items))
        sender.cancel()
    }

    @Test func refusedUnlockSendsNothing() async throws {
        let link = FakeLink()
        let calls = Calls()
        let code = PairingCode.generate(role: .receives, device: "Lee's iPad")
        let sender = sender(link, calls: calls, unlocks: false)
        async let receiving = receivingDevice(link, code: code, name: "Lee's iPad")
        await sender.scanned(code.text)
        let channel = try await receiving
        defer { channel.close() }

        await sender.send()
        #expect(sender.state == .confirm(device: "Lee's iPad", items: Self.items))
        #expect(calls.exports == 0)
        sender.cancel()
        // The next record is the stop: no bundle went before it.
        await #expect(throws: SetupError.stopped) { try await channel.receiveBundle() }
    }

    @Test func cancelOnSenderStopsReceiver() async throws {
        let link = FakeLink()
        let calls = Calls()
        let receiver = receiver(link, calls: calls)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link)
        await sender.scanned(code.text)
        #expect(await eventually { receiver.state == .waiting })

        sender.cancel()
        #expect(await eventually { receiver.state == .failed(.stopped) })
        #expect(calls.imports == 0)
    }

    @Test func aSenderThatGoesStopsReceiver() async throws {
        let link = FakeLink()
        let receiver = receiver(link)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        var sender: SendSetupModel? = sender(link)
        await sender?.scanned(code.text)
        #expect(await eventually { receiver.state == .waiting })

        sender = nil
        #expect(await eventually { receiver.state == .failed(.stopped) })
    }

    @Test func aReceiverThatGoesStopsListening() async throws {
        let link = FakeLink()
        var receiver: ReceiveSetupModel? = receiver(link, codeLife: .seconds(60))
        await receiver?.start()
        #expect(await eventually { link.isWaiting })

        receiver = nil
        #expect(await eventually { !link.isWaiting })
    }

    @Test func aNewCodeNeverMeetsAnOldRestore() async throws {
        let link = FakeLink()
        let receiver = receiver(link, importTakes: .milliseconds(300))
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link)
        await sender.scanned(code.text)
        let sending = Task { await sender.send() }
        #expect(await eventually { receiver.state == .restoring })

        await receiver.newCode()
        #expect(receiver.state == .restoring)
        await sending.value
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(await eventually { if case .report = receiver.state { true } else { false } })
    }

    @Test func theSenderHearsDoneBeforeTheNotificationsAsk() async throws {
        let link = FakeLink()
        let gate = Gate()
        let notices = SetupNotices(anyOn: { true }, ask: { await gate.pass() })
        let receiver = receiver(link, notices: notices)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link)
        await sender.scanned(code.text)

        await sender.send()
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(await eventually { gate.asked })
        if case .report = receiver.state {} else { Issue.record("no report while asking: \(receiver.state)") }
        gate.open()
    }

    @Test func aConnectionThatNeverProvesTheCodeSpendsIt() async throws {
        let link = FakeLink()
        let receiver = receiver(link, handshakeTimeout: .milliseconds(100))
        await receiver.start()
        let silent = try await link.connectStream()
        defer { silent.close() }
        #expect(await eventually { receiver.state == .failed(.spent) })
    }

    @Test func anExportThatFailsStopsTheReceiver() async throws {
        let link = FakeLink()
        let calls = Calls()
        let receiver = receiver(link, calls: calls)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link, exportFails: true)
        await sender.scanned(code.text)

        await sender.send()
        #expect(sender.state == .failed(.unavailable))
        #expect(await eventually { receiver.state == .failed(.stopped) })
        #expect(calls.imports == 0)
    }

    @Test func aCancelDuringTheUnlockSendsNothing() async throws {
        let link = FakeLink()
        let calls = Calls()
        let gate = Gate()
        let code = PairingCode.generate(role: .receives, device: "Lee's iPad")
        let sender = sender(link, calls: calls, unlock: gate)
        async let receiving = receivingDevice(link, code: code, name: "Lee's iPad")
        await sender.scanned(code.text)
        let channel = try await receiving
        defer { channel.close() }

        let sending = Task { await sender.send() }
        #expect(await eventually { gate.asked })
        sender.cancel()
        #expect(sender.state == .scanning)
        gate.open()
        await sending.value
        #expect(sender.state == .scanning)
        #expect(calls.exports == 0)
        await #expect(throws: SetupError.stopped) { try await channel.receiveBundle() }
    }

    @Test func wrongCodeNeverConnects() async throws {
        let link = FakeLink()
        let sender = sender(link)
        await sender.scanned("https://example.org")
        #expect(sender.state == .wrongCode(.notACode))
        await sender.scanned(PairingCode.generate(role: .sends, device: "Lee's iPad").text)
        #expect(sender.state == .wrongCode(.sendsToo))
        var newer = PairingCode.generate(role: .receives, device: "Lee's iPad")
        newer.version = PairingCode.currentVersion + 1
        await sender.scanned(newer.text)
        #expect(sender.state == .wrongCode(.newerVersion))
        #expect(link.connects == 0)
    }

    @Test func aReceiverNotFoundIsToldApart() async throws {
        let sender = SendSetupModel(
            exchange: SetupExchange(parts: [], device: "Pat's phone", parameters: SetupModelTests.quick),
            unlock: SetupModelTests.FakeUnlock(answer: true), connect: { _ throws(SetupError) in throw .timedOut },
            handshakeTimeout: Self.short, timeout: Self.short)
        await sender.scanned(PairingCode.generate(role: .receives, device: "Lee's iPad").text)
        #expect(sender.state == .failed(.notFound))
        sender.scanAgain()
        #expect(sender.state == .scanning)
    }

    @Test func strangerSpendsTheCode() async throws {
        let link = FakeLink()
        let receiver = receiver(link)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))

        var stranger = code
        stranger.secret = PairingCode.generate(role: .receives, device: "").secret
        let stream = try await link.connectStream()
        await #expect(throws: SetupError.handshakeFailed) {
            try await SetupTransfer.connect(
                stream, code: stranger, asInitiator: true, handshakeTimeout: Self.short, timeout: Self.short)
        }
        #expect(await eventually { receiver.state == .failed(.handshake) })

        await receiver.newCode()
        let next = try #require(shownCode(of: receiver))
        #expect(next.secret != code.secret)
        #expect(next.service != code.service)
        receiver.cancel()
    }

    @Test func codeExpires() async throws {
        let link = FakeLink()
        let receiver = receiver(link, codeLife: .milliseconds(100))
        let before = Date()
        await receiver.start()
        guard case .showing(_, let expires) = receiver.state else {
            Issue.record("no code: \(receiver.state)")
            return
        }
        #expect(expires > before)
        #expect(await eventually { receiver.state == .failed(.expired) })
    }

    @Test func lostMidBundleRestoresNothing() async throws {
        let link = FakeLink()
        let calls = Calls()
        let receiver = receiver(link, calls: calls)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))

        // The test as the sending device, whose link breaks a little way into the bundle.
        let stream = CuttingStream(try await link.connectStream(), limit: 50 + 4_000)
        let channel = try await SetupTransfer.connect(
            stream, code: code, asInitiator: true, handshakeTimeout: Self.short, timeout: Self.short)
        #expect(try await channel.receiveHello() == "Pat's iPad")
        let part = AccountsPart(held: Self.addresses, calls: Calls(), padding: 200_000)
        let exchange = SetupExchange(parts: [part], device: "Pat's phone", parameters: SetupModelTests.quick)
        let bundle = try await exchange.exportBundle().bundle
        await #expect(throws: SetupError.self) { try await channel.sendBundle(bundle) }

        #expect(await eventually { receiver.state == .failed(.lost) })
        #expect(calls.imports == 0)
    }
}
