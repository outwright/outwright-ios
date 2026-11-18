// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import Observation
public import OutwrightSetup
public import OutwrightSync

/// Sending the setup straight to another device: scan the code it shows, connect, confirm and send.
@MainActor @Observable
public final class SendSetupModel {
    /// Why a scanned code is not one to send to.
    public enum Problem: Error, Sendable, Equatable {
        /// Not a pairing code.
        case notACode
        /// The other device sends too: it shows the code to send from, not to receive with.
        case sendsToo
        /// A code of a newer version of the app.
        case newerVersion
    }

    /// Why sending ended.
    public enum Failure: Error, Sendable, Equatable {
        /// The other device was not found: it is not nearby, or one of the two is not allowed on the local network.
        case notFound
        /// The other device does not hold the code scanned (or the link was tampered with).
        case handshake
        /// The other device cancelled.
        case stopped
        /// The connection dropped.
        case lost
        /// The other device stopped answering.
        case timedOut
        /// Something in the setup can never be sent (too large, or out of shape).
        case cannotBeMade
        /// A piece of the setup could not be read on this device right now (its keychain refused): worth trying
        /// again.
        case unavailable
    }

    public enum State: Sendable, Equatable {
        case scanning
        case wrongCode(Problem)
        /// Connecting to the device named in the code; possibly "".
        case connecting(device: String)
        /// Connected: what will be sent, to the device by the name it gave; possibly "".
        case confirm(device: String, items: [SetupItem])
        case sending
        /// The setup went: the other device restores it, possibly after asking its owner first.
        case waitingForReceiver
        case sent(device: String)
        case failed(Failure)
    }

    public typealias Connect = @Sendable (PairingCode) async throws(SetupError) -> any SetupStream

    public private(set) var state: State = .scanning
    /// What would be sent, read without a secret (`loadItems`), for the screen before a code is scanned.
    public private(set) var items: [SetupItem] = []

    @ObservationIgnored private let exchange: SetupExchange
    @ObservationIgnored private let unlock: any DeviceUnlock
    @ObservationIgnored private let connect: Connect
    @ObservationIgnored private let handshakeTimeout: Duration
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var session: DirectSession?
    /// The wait for the receiver's `done`, begun at the confirmation: the receiver leaving shows while the
    /// confirmation is up.
    @ObservationIgnored private var done: Task<SetupError?, Never>?

    /// Finds the device advertising the code's service on the local network and connects to it.
    public static let nearby: Connect = { code throws(SetupError) in
        try await SetupConnector.connect(service: code.service)
    }

    public init(
        exchange: SetupExchange, unlock: any DeviceUnlock, connect: @escaping Connect = SendSetupModel.nearby,
        handshakeTimeout: Duration = .seconds(30), timeout: Duration = .seconds(300)
    ) {
        self.exchange = exchange
        self.unlock = unlock
        self.connect = connect
        self.handshakeTimeout = handshakeTimeout
        self.timeout = timeout
    }

    /// A model that goes mid-transfer ends it, telling the other device.
    deinit {
        session?.end(stop: true)
    }

    public func loadItems() async {
        items = await exchange.items()
    }

    /// Reads a scanned code; a code to send to connects, handshakes and shows what will be sent. Ignored while a
    /// code is already being followed.
    public func scanned(_ text: String) async {
        switch state {
        case .scanning, .wrongCode: break
        default: return
        }
        let code: PairingCode
        switch Self.read(text) {
        case .success(let read): code = read
        case .failure(let problem):
            state = .wrongCode(problem)
            return
        }
        let session = DirectSession()
        self.session = session
        state = .connecting(device: code.device)
        let (connect, exchange, handshakeTimeout, timeout) = (connect, exchange, handshakeTimeout, timeout)
        let work = Task.detached {
            await Self.establish(
                code, in: session, connect: connect, exchange: exchange,
                timeouts: (handshake: handshakeTimeout, each: timeout))
        }
        session.run { work.cancel() }
        let outcome = await work.value
        guard self.session === session, !session.isEnded else { return }
        switch outcome {
        case .success(let (device, items)):
            state = .confirm(device: device, items: items)
            if let channel = session.channel { awaitDone(on: channel, in: session) }
        case .failure(let failure):
            end(session)
            state = .failed(failure)
        }
    }

    /// Connects, handshakes as the initiator and reads the other device's name and what will be sent.
    private nonisolated static func establish(
        _ code: PairingCode, in session: DirectSession, connect: Connect, exchange: SetupExchange,
        timeouts: (handshake: Duration, each: Duration)
    ) async -> Result<(String, [SetupItem]), Failure> {
        let stream: any SetupStream
        do {
            stream = try await connect(code)
        } catch {
            // A refused local network permission finds nothing, as a device out of reach does.
            return .failure(.notFound)
        }
        guard session.hold(stream) else { return .failure(.lost) }
        do throws(SetupError) {
            let channel = try await SetupTransfer.connect(
                stream, code: code, asInitiator: true, handshakeTimeout: timeouts.handshake, timeout: timeouts.each)
            guard session.hold(channel) else { return .failure(.lost) }
            let device = try await channel.receiveHello()
            return .success((device, await exchange.items()))
        } catch {
            return .failure(failure(error))
        }
    }

    /// Waits for the receiver's `done` from the confirmation on, timed only once the bundle went: a `stop` or a
    /// dropped link fails the transfer while the confirmation is still up, before any unlock or export. Once
    /// sending, `send` reads the outcome.
    private func awaitDone(on channel: SetupChannel, in session: DirectSession) {
        let done = Task.detached { () -> SetupError? in
            do throws(SetupError) {
                _ = try await channel.receiveDone()
                return nil
            } catch {
                return error
            }
        }
        self.done = done
        Task { [weak self] in
            let error = await done.value
            self?.heardBeforeSending(error, in: session)
        }
    }

    /// The wait for `done` ended. While the confirmation is up that is the transfer's end: a `done` before any
    /// bundle is out of order, so lost.
    private func heardBeforeSending(_ error: SetupError?, in session: DirectSession) {
        guard self.session === session, !session.isEnded, case .confirm = state else { return }
        end(session)
        state = .failed(error.map(Self.failure) ?? .lost)
    }

    /// Unlocks, then sends the setup and waits for the other device to restore it. A refused unlock stays on the
    /// confirmation and sends nothing.
    public func send() async {
        guard case .confirm(let device, _) = state, let session, let channel = session.channel, let done else { return }
        guard await unlock.unlock(reason: L10n.string("Unlock to move your accounts and keys.")) else { return }
        guard self.session === session, !session.isEnded, case .confirm = state else { return }
        state = .sending
        let exchange = exchange
        // Detached: reading every part and sealing it into the channel is never on the main actor.
        let work = Task.detached { [weak self] () -> Failure? in
            let bundle: SetupBundle
            do throws(SetupError) {
                bundle = try await exchange.exportBundle().bundle
            } catch {
                return error == .tooLarge || error == .malformed ? .cannotBeMade : .unavailable
            }
            // Cancelled while exporting: the stop goes out instead of the bundle.
            guard !Task.isCancelled else { return .lost }
            do throws(SetupError) {
                try await channel.sendBundle(bundle)
            } catch {
                return Self.failure(error)
            }
            await self?.bundleWent(in: session)
            return await done.value.map(Self.failure)
        }
        session.run { work.cancel() }
        let failure = await work.value
        guard self.session === session, !session.isEnded else { return }
        guard let failure else {
            end(session)
            state = .sent(device: device)
            return
        }
        // The other device still waits for a setup that will not come: it is told.
        end(session, stop: failure == .cannotBeMade || failure == .unavailable)
        state = .failed(failure)
    }

    /// The bundle went: what is left is the other device's restore, which may first ask its owner.
    private func bundleWent(in session: DirectSession) {
        guard self.session === session, !session.isEnded, state == .sending else { return }
        state = .waitingForReceiver
    }

    /// Ends the transfer and goes back to the scanner: the other device is told when connected, and the link
    /// closes. Work still under way finds its session gone and changes nothing.
    public func cancel() {
        if let session { end(session, stop: true) }
        state = .scanning
    }

    /// Back to the scanner after a wrong code or a failure.
    public func scanAgain() {
        cancel()
    }

    private func end(_ session: DirectSession, stop: Bool = false) {
        session.end(stop: stop)
        if self.session === session {
            self.session = nil
            done = nil
        }
    }

    /// A scanned code to send to, or what is wrong with it.
    static func read(_ text: String) -> Result<PairingCode, Problem> {
        let code: PairingCode
        do {
            code = try PairingCode(text: text)
        } catch {
            return .failure(error == .unsupported ? .newerVersion : .notACode)
        }
        return code.role == .receives ? .success(code) : .failure(.sendsToo)
    }

    nonisolated static func failure(_ error: SetupError) -> Failure {
        switch error {
        case .handshakeFailed: .handshake
        case .stopped: .stopped
        case .timedOut: .timedOut
        case .tooLarge: .cannotBeMade
        case .connectionLost, .malformed, .unsupported, .wrongPassphrase, .unavailable: .lost
        }
    }
}
