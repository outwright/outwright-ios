// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightSetup
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

/// The direct transfer when an owner prompt waits, the other device leaves, or what came is not for this app.
extension DirectSetupModelTests {
    // MARK: Waiting for the owner

    /// The new device asks for Contacts after it told the sender it is done: a prompt left unanswered never
    /// fails the move on the sender.
    @Test func aContactsAskThatNeverAnswersNeverHoldsTheSender() async throws {
        let link = FakeLink()
        let gate = Gate()
        let contacts = SetupPhoneContacts(
            saving: { $0 }, ask: { await gate.pass() }, turnOff: { _ in [] })
        let receiver = receiver(link, phoneContacts: contacts)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link)
        await sender.scanned(code.text)

        confirming(receiver)
        await sender.send()
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(await eventually { gate.asked })
        if case .report = receiver.state {} else { Issue.record("no report while asking: \(receiver.state)") }
        gate.open()
    }

    /// Contacts refused after the report showed: the report says which accounts no longer save to the phone,
    /// and the notifications ask comes after the Contacts one.
    @Test func aRefusedContactsAskUpdatesTheReport() async throws {
        let link = FakeLink()
        let order = Mutex<[String]>([])
        let contacts = SetupPhoneContacts(
            saving: { $0 },
            ask: {
                order.withLock { $0.append("contacts") }
                return false
            },
            turnOff: { $0 })
        let notices = SetupNotices(anyOn: { true }, ask: {
            order.withLock { $0.append("notices") }
            return true
        })
        let receiver = receiver(link, notices: notices, phoneContacts: contacts)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link)
        await sender.scanned(code.text)

        confirming(receiver)
        await sender.send()
        #expect(sender.state == .sent(device: "Pat's iPad"))
        let expected = SetupImportReport(added: Self.items, phoneContactsOff: Self.items)
        #expect(await eventually { receiver.state == .report(expected) })
        #expect(await eventually { order.withLock { $0 } == ["contacts", "notices"] })
    }

    // MARK: The other device leaving

    @Test func aReceiverThatCancelsAtTheConfirmationFailsTheSender() async throws {
        let link = FakeLink()
        let calls = Calls()
        let gate = Gate()
        let receiver = receiver(link)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let sender = sender(link, calls: calls, unlock: gate)
        await sender.scanned(code.text)
        #expect(sender.state == .confirm(device: "Pat's iPad", items: Self.items))

        receiver.cancel()
        #expect(await eventually { sender.state == .failed(.stopped) })
        #expect(!gate.asked)
        #expect(calls.exports == 0)
    }

    @Test func aLinkThatDropsAtTheConfirmationFailsTheSender() async throws {
        let link = FakeLink()
        let code = PairingCode.generate(role: .receives, device: "Lee's iPad")
        let sender = sender(link)
        async let receiving = receivingDevice(link, code: code, name: "Lee's iPad")
        await sender.scanned(code.text)
        let channel = try await receiving
        #expect(sender.state == .confirm(device: "Lee's iPad", items: Self.items))

        channel.close()
        #expect(await eventually { sender.state == .failed(.lost) })
    }

    /// The wait for `done` starts at the confirmation, but its time only once the bundle went.
    @Test func aLongConfirmationStillSends() async throws {
        let link = FakeLink()
        let code = PairingCode.generate(role: .receives, device: "Lee's iPad")
        let sender = sender(link, timeout: .milliseconds(300))
        async let receiving = receivingDevice(link, code: code, name: "Lee's iPad")
        await sender.scanned(code.text)
        let channel = try await receiving
        defer { channel.close() }
        #expect(sender.state == .confirm(device: "Lee's iPad", items: Self.items))
        try await Task.sleep(for: .milliseconds(800))
        #expect(sender.state == .confirm(device: "Lee's iPad", items: Self.items))

        async let answered: Void = answer(channel)
        await sender.send()
        try await answered
        #expect(sender.state == .sent(device: "Lee's iPad"))
    }

    // MARK: What came

    @Test func aBundleFromANewerAppIsToldApartAndStopsTheSender() async throws {
        let link = FakeLink()
        let calls = Calls()
        let receiver = receiver(link, calls: calls)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let channel = try await sendingDevice(link, code: code)
        defer { channel.close() }
        let exchange = SetupExchange(
            parts: [AccountsPart(held: Self.addresses, calls: Calls())], device: "Pat's phone",
            parameters: SetupModelTests.quick)
        var bundle = try await exchange.exportBundle().bundle
        bundle.version = SetupBundle.currentVersion + 1
        try await channel.sendBundle(bundle)

        #expect(await eventually { receiver.state == .failed(.newerVersion) })
        await #expect(throws: SetupError.stopped) { try await channel.receiveDone() }
        #expect(calls.imports == 0)
    }

    @Test func theReportSaysWhereItCameFrom() async throws {
        let link = FakeLink()
        let receiver = receiver(link)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let channel = try await sendingDevice(link, code: code)
        defer { channel.close() }
        let exchange = SetupExchange(
            parts: [AccountsPart(held: Self.addresses, calls: Calls())], device: "Pat\u{202E}s phone",
            parameters: SetupModelTests.quick)
        let bundle = try await exchange.exportBundle().bundle
        try await channel.sendBundle(bundle)
        confirming(receiver)
        _ = try await channel.receiveDone()

        #expect(await eventually { if case .report = receiver.state { true } else { false } })
        // The bundle carries whole seconds.
        let created = Date(timeIntervalSince1970: bundle.created.timeIntervalSince1970.rounded(.down))
        #expect(receiver.origin == SetupOrigin(device: "Pats phone", created: created))
    }

    // MARK: The code

    /// A handshake or hello that runs out spends the code, but no stranger is blamed.
    @Test func aTimeoutDuringTheHandshakeIsNotAStranger() {
        #expect(ReceiveSetupModel.connectFailure(.timedOut) == .spent)
        #expect(ReceiveSetupModel.connectFailure(.handshakeFailed) == .handshake)
        #expect(ReceiveSetupModel.connectFailure(.connectionLost) == .lost)
    }

    /// iOS may end the listener while the app is in the background: coming back shows a new code.
    @Test func comingBackFromTheBackgroundShowsANewCode() async throws {
        let link = FakeLink()
        let receiver = receiver(link, codeLife: .seconds(60))
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        await receiver.cameBackFromBackground()
        let next = try #require(shownCode(of: receiver))
        #expect(next.secret != code.secret)
        receiver.cancel()
    }

    /// A listener the system ended fails the receiver as lost, so it offers a new code.
    @Test func aListenerThatDiesFailsAsLost() async throws {
        let link = FakeLink()
        let listen: ReceiveSetupModel.Listen = { _ throws(SetupError) in
            { _ throws(SetupError) in throw .connectionLost }
        }
        let receiver = receiver(link, listen: listen)
        await receiver.start()
        #expect(await eventually { receiver.state == .failed(.lost) })
    }

    /// iOS may report the ended listener before the app is in front again: back in front, a new code replaces
    /// the lost one, as nobody used it.
    @Test func aListenerLostWhileAwayIsReplacedOnReturn() async throws {
        let link = FakeLink()
        let listens = Mutex(0)
        let listen: ReceiveSetupModel.Listen = { code throws(SetupError) in
            let first = listens.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if first { return { _ throws(SetupError) in throw .connectionLost } }
            return try await link.listen(code)
        }
        let receiver = receiver(link, codeLife: .seconds(60), listen: listen)
        await receiver.start()
        #expect(await eventually { receiver.state == .failed(.lost) })

        await receiver.cameBackFromBackground()
        #expect(shownCode(of: receiver) != nil)
        receiver.cancel()
    }

    /// A transfer lost after a device connected stays reported on return: only an untouched code is replaced.
    @Test func aTransferLostWhileAwayStaysReported() async throws {
        let link = FakeLink()
        let receiver = receiver(link)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let channel = try await sendingDevice(link, code: code)
        #expect(await eventually { receiver.state == .waiting })
        channel.close()
        #expect(await eventually { receiver.state == .failed(.lost) })

        await receiver.cameBackFromBackground()
        #expect(receiver.state == .failed(.lost))
    }

    /// The time shown for the code is the time its listening has.
    @Test func theShownExpiryIsTheListeningsEnd() async throws {
        let link = FakeLink()
        let asked = Mutex<(at: Date, within: Duration)?>(nil)
        let listen: ReceiveSetupModel.Listen = { _ throws(SetupError) in
            { within throws(SetupError) in
                asked.withLock { $0 = (Date(), within) }
                try? await Task.sleep(for: .seconds(60))
                throw .timedOut
            }
        }
        let receiver = receiver(link, codeLife: .seconds(60), listen: listen)
        await receiver.start()
        guard case .showing(_, let expires) = receiver.state else {
            Issue.record("no code: \(receiver.state)")
            return
        }
        #expect(await eventually { asked.withLock { $0 } != nil })
        let (when, within) = try #require(asked.withLock { $0 })
        let end = when.addingTimeInterval(TimeInterval(within.components.seconds))
            .addingTimeInterval(TimeInterval(within.components.attoseconds) / 1e18)
        #expect(abs(end.timeIntervalSince(expires)) < 0.05)
        receiver.cancel()
    }

    // MARK: Ending

    /// A cancel stops the work under way at once, without waiting for the stop to go out.
    @Test func aCancelStopsTheWorkBeforeTheStopGoes() async throws {
        let code = PairingCode.generate(role: .receives, device: "Lee's iPad")
        let (mine, theirs) = SetupStreamPair.make()
        async let other = SetupTransfer.connect(theirs, code: code, asInitiator: false)
        let channel = try await SetupTransfer.connect(mine, code: code, asInitiator: true)
        let held = try await other
        defer { held.close() }
        theirs.stopReading()

        let session = DirectSession()
        #expect(session.hold(channel))
        let cancelled = Mutex(false)
        session.run { cancelled.withLock { $0 = true } }
        session.end(stop: true, grace: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        #expect(cancelled.withLock { $0 })
    }
}

/// Moving by code onto a device that already has something different: the receiver asks before it restores,
/// while the sender waits for `done`.
extension DirectSetupModelTests {
    /// A receiver on `device`, through the real accounts part.
    func receiver(
        _ link: FakeLink, device: SetupDifferenceChoiceTests.Device
    ) -> ReceiveSetupModel {
        ReceiveSetupModel(
            setup: device.model(), device: "Pat's iPad", listen: link.listen, codeLife: Self.short,
            handshakeTimeout: Self.short, timeout: Self.short)
    }

    /// A sender whose device has the account with `password`.
    func sender(_ link: FakeLink, password: String) throws -> SendSetupModel {
        SendSetupModel(
            exchange: try SetupDifferenceChoiceTests.Device(password: password).exchange(),
            unlock: SetupModelTests.FakeUnlock(answer: true), connect: link.connect,
            handshakeTimeout: Self.short, timeout: Self.short)
    }

    /// The receiver showing its code and the sender confirmed, sending in `sending`.
    func connected(
        _ receiver: ReceiveSetupModel, _ sender: SendSetupModel
    ) async throws -> Task<Void, Never> {
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        await sender.scanned(code.text)
        #expect(await eventually { receiver.state == .waiting })
        return Task { await sender.send() }
    }

    /// Whether the receiver asks the owner.
    var choosing: @MainActor (ReceiveSetupModel) -> Bool {
        { if case .choosing = $0.state { true } else { false } }
    }

    /// The list shows even with nothing that differs (its accounts have switches); the button restores without
    /// a question.
    @Test func noDifferenceShowsTheListThenRestoresWithoutAsking() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "hunter2")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)

        #expect(await eventually { choosing(receiver) })
        await receiver.restoreChosen()
        #expect(receiver.setup.question == nil)
        await sending.value
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(await eventually { if case .report = receiver.state { true } else { false } })
        #expect(device.password == "hunter2")
    }

    @Test func aDifferenceIsAskedBeforeRestoring() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)

        #expect(await eventually { choosing(receiver) })
        guard case .choosing(let preview) = receiver.state else { return }
        #expect(preview.differences.map(\.id) == ["password:pat@example.org"])
        // Nothing is asked before the button.
        #expect(receiver.setup.question == nil)
        #expect(device.password == "chosen here")
        // The setup went: the sender waits for the other device, no longer sending.
        #expect(await eventually { sender.state == .waitingForReceiver })
        // Back from the background, a transfer whose link lives keeps its question.
        await receiver.cameBackFromBackground()
        #expect(choosing(receiver))

        receiver.cancel()
        await sending.value
    }

    @Test func restoringTheChosenSendsDone() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)
        #expect(await eventually { choosing(receiver) })

        let restoring = Task { await receiver.restoreChosen() }
        #expect(await eventually { receiver.setup.question != nil })
        receiver.setup.answer(useOther: true)
        await restoring.value
        await sending.value
        #expect(sender.state == .sent(device: "Pat's iPad"))
        #expect(device.password == "hunter2")
        guard case .report(let report) = receiver.state else {
            Issue.record("no report: \(receiver.state)")
            return
        }
        #expect(report.replaced == [SetupItem(kind: .account, label: "pat@example.org")])
    }

    @Test func cancelWhileChoosingStopsTheSender() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)
        #expect(await eventually { choosing(receiver) })

        receiver.cancel()
        await sending.value
        #expect(sender.state == .failed(.stopped))
        await receiver.restoreChosen()
        #expect(device.password == "chosen here")
    }

    @Test func aStopWhileChoosingRestoresNothing() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)
        #expect(await eventually { choosing(receiver) })

        sender.cancel()
        await sending.value
        #expect(await eventually { receiver.state == .failed(.stopped) })
        #expect(device.password == "chosen here")
        await receiver.restoreChosen()
        #expect(receiver.state == .failed(.stopped))
        #expect(device.password == "chosen here")
    }

    /// The sender gave up waiting (its time ran out, or the link dropped) before the owner answered: nothing is
    /// restored, and the screen says the link is gone.
    @Test func aLinkLostWhileChoosingRestoresNothing() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        await receiver.start()
        let code = try #require(shownCode(of: receiver))
        let channel = try await sendingDevice(link, code: code)
        let bundle = try await SetupDifferenceChoiceTests.Device(password: "hunter2").exchange().exportBundle().bundle
        try await channel.sendBundle(bundle)
        #expect(await eventually { choosing(receiver) })

        channel.close()
        #expect(await eventually { receiver.state == .failed(.lost) })
        await receiver.restoreChosen()
        #expect(receiver.state == .failed(.lost))
        #expect(device.password == "chosen here")
    }

    /// The other device stops while a question is up: the question goes, nothing is restored, and the screen
    /// says the other device stopped.
    @Test func otherDeviceLeavingDuringQuestions() async throws {
        let link = FakeLink()
        let device = try SetupDifferenceChoiceTests.Device(password: "chosen here")
        let receiver = receiver(link, device: device)
        let sender = try sender(link, password: "hunter2")
        let sending = try await connected(receiver, sender)
        #expect(await eventually { choosing(receiver) })
        let restoring = Task { await receiver.restoreChosen() }
        #expect(await eventually { receiver.setup.question != nil })

        sender.cancel()
        await sending.value
        await restoring.value

        #expect(await eventually { receiver.state == .failed(.stopped) })
        #expect(receiver.setup.question == nil)
        #expect(device.password == "chosen here")
    }
}
