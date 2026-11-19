// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightSetup
public import OutwrightSync

/// Receiving the setup straight from another device: show a code, wait for the device that scans it, restore what
/// it sends.
@MainActor @Observable
public final class ReceiveSetupModel {
    /// Why receiving ended.
    public enum Failure: Error, Sendable, Equatable {
        /// No device connected while the code was valid.
        case expired
        /// The device that connected does not hold the code (or the link was tampered with): the code is spent.
        case handshake
        /// The other device cancelled.
        case stopped
        /// The connection dropped, or the other device stopped answering.
        case lost
        /// This device could not listen on the local network.
        case cannotListen
        /// A device connected and did not finish connecting in time: the code is spent, but no stranger is blamed.
        case spent
        /// The setup came from a newer version of the app, which this one cannot read.
        case newerVersion
    }

    public enum State: Sendable, Equatable {
        case starting
        /// The code to scan, valid until `expires`.
        case showing(PairingCode, expires: Date)
        /// Connected; the owner confirms on the other device.
        case waiting
        /// The setup came: the owner sees what comes, switches accounts off, taps the button and answers what
        /// differs before anything is restored, while the other device waits for `done`.
        case choosing(SetupPreview)
        case restoring
        case report(SetupImportReport)
        case failed(Failure)
    }

    /// Accepting the one connection that comes within the time.
    public typealias Accept = @Sendable (Duration) async throws(SetupError) -> any SetupStream
    /// Starts listening for a code, and returns how to accept its connection.
    public typealias Listen = @Sendable (PairingCode) async throws(SetupError) -> Accept

    public private(set) var state: State = .starting
    /// Where the setup came from, once it came.
    public private(set) var origin: SetupOrigin?

    /// Restores what comes, and holds the owner's choices while they are asked.
    @ObservationIgnored let setup: SetupModel
    @ObservationIgnored private let device: String
    @ObservationIgnored private let listen: Listen
    @ObservationIgnored private let restored: @MainActor () async -> Void
    @ObservationIgnored private let codeLife: Duration
    @ObservationIgnored private let handshakeTimeout: Duration
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var session: DirectSession?
    /// Whether the failure shown came while listening, before any device connected: the code was never used.
    @ObservationIgnored private var failedListening = false

    /// Listens on the local network, advertised under the code's service; listening stops at the first connection.
    public static let nearby: Listen = { code throws(SetupError) in
        let listener = SetupListener(service: code.service)
        _ = try await listener.start()
        return { within throws(SetupError) in
            defer { listener.stop() }
            return try await listener.accept(within: within)
        }
    }

    /// `restored` is called after a restore that changed anything (the app reads its new accounts).
    public init(
        setup: SetupModel, device: String, listen: @escaping Listen = ReceiveSetupModel.nearby,
        restored: @escaping @MainActor () async -> Void = {}, codeLife: Duration = .seconds(300),
        handshakeTimeout: Duration = .seconds(30), timeout: Duration = .seconds(300)
    ) {
        self.setup = setup
        self.device = device
        self.listen = listen
        self.restored = restored
        self.codeLife = codeLife
        self.handshakeTimeout = handshakeTimeout
        self.timeout = timeout
    }

    /// A model that goes mid-transfer ends it, telling the other device.
    deinit {
        session?.end(stop: true)
    }

    /// Makes a new code and listens for it; returns once the code shows (or listening failed). The rest goes on
    /// until the report or a failure. Ignored while a restore is under way.
    public func start() async {
        guard state != .restoring else { return }
        if let session { end(session, stop: true) }
        let session = DirectSession()
        self.session = session
        state = .starting
        let code = PairingCode.generate(role: .receives, device: device)
        let listen = listen
        let starting = Task.detached { () -> Result<Accept, SetupError> in
            do throws(SetupError) {
                return .success(try await listen(code))
            } catch {
                return .failure(error)
            }
        }
        session.run { starting.cancel() }
        let started = await starting.value
        guard self.session === session, !session.isEnded else { return }
        guard case .success(let accept) = started else {
            end(session)
            state = .failed(.cannotListen)
            return
        }
        // One end for the code shown and its listening: the accept gets what is left of it when it starts.
        let end = ContinuousClock.now.advanced(by: codeLife)
        state = .showing(code, expires: Date().addingTimeInterval(Self.seconds(codeLife)))
        let (handshakeTimeout, timeout, device) = (handshakeTimeout, timeout, device)
        // Holds the model weakly: one that goes ends the session from its deinit.
        let work = Task.detached { [weak self] in
            let channel: SetupChannel
            let answered = await Self.answer(
                accept, code: code, in: session, device: device,
                timing: Timing(end: end, handshake: handshakeTimeout, each: timeout))
            switch answered {
            case .none: return
            case .failure(let unanswered)?:
                await self?.failed(session, unanswered.failure, listening: unanswered.listening)
                return
            case .success(let connected)?: channel = connected
            }
            session.linkEndsWork()
            await self?.connected(session)
            do throws(SetupError) {
                let bundle = try await channel.receiveBundle()
                guard await self?.received(bundle, over: channel, in: session) == true else { return }
            } catch {
                // A setup this app cannot read: the other device is told at once, not left waiting for `done`.
                await self?.failed(session, Self.failure(error), stop: error == .unsupported)
                return
            }
            // The owner is asked: the other device leaving meanwhile (a stop, its wait for `done` run out, a
            // dropped link) ends the transfer with nothing restored.
            let left = await channel.untilLeft()
            await self?.left(session, left)
        }
        session.run { work.cancel() }
    }

    /// When the code's life ends, how long the handshake may take, and each send or receive after it.
    private struct Timing: Sendable {
        var end: ContinuousClock.Instant
        var handshake: Duration
        var each: Duration
    }

    /// Why answering failed, and whether it was while listening, before any device connected.
    private struct Unanswered: Error {
        var failure: Failure
        var listening = false
    }

    /// Accepts the connection, handshakes as the responder and says this device's name: the channel, why it
    /// failed, or nil when the session ended meanwhile.
    private nonisolated static func answer(
        _ accept: Accept, code: PairingCode, in session: DirectSession, device: String,
        timing: Timing
    ) async -> Result<SetupChannel, Unanswered>? {
        let stream: any SetupStream
        do throws(SetupError) {
            stream = try await accept(ContinuousClock.now.duration(to: timing.end))
        } catch {
            return .failure(Unanswered(failure: error == .timedOut ? .expired : failure(error), listening: true))
        }
        guard session.hold(stream) else { return nil }
        do throws(SetupError) {
            let channel = try await SetupTransfer.connect(
                stream, code: code, asInitiator: false, handshakeTimeout: timing.handshake, timeout: timing.each)
            guard session.hold(channel) else { return nil }
            try await channel.sendHello(device: device)
            return .success(channel)
        } catch {
            return .failure(Unanswered(failure: connectFailure(error)))
        }
    }

    /// Why connecting failed after a device came. One that connects and never proves the code spends it, as a
    /// wrong code does, but only a wrong code is a stranger.
    nonisolated static func connectFailure(_ error: SetupError) -> Failure {
        error == .timedOut ? .spent : failure(error)
    }

    /// A new code in place of one that expired or was spent. Ignored while a restore is under way.
    public func newCode() async {
        await start()
    }

    /// The app is in front again after it was in the background, where iOS may have ended the listening: a code
    /// still shown, or one whose listening was lost before any device connected (iOS may report that before the
    /// app is in front), is replaced by a new one.
    public func cameBackFromBackground() async {
        switch state {
        case .showing: await start()
        case .failed(.lost) where failedListening: await start()
        default: return
        }
    }

    /// Ends the transfer: the other device is told when connected, and the link closes. A restore under way is
    /// finished, and the other device is told it was; while the owner is asked, nothing is restored.
    public func cancel() {
        guard state != .restoring, let session else { return }
        setup.endQuestions()
        end(session, stop: true)
    }

    private func connected(_ session: DirectSession) {
        guard self.session === session, !session.isEnded else { return }
        state = .waiting
    }

    private func failed(_ session: DirectSession, _ failure: Failure, stop: Bool = false, listening: Bool = false) {
        guard self.session === session, !session.isEnded else { return }
        end(session, stop: stop)
        failedListening = listening
        state = .failed(failure)
    }

    /// What came is read and shown, and the owner is asked; true while the other device waits.
    private func received(_ bundle: SetupBundle, over channel: SetupChannel, in session: DirectSession) async -> Bool {
        guard self.session === session, !session.isEnded else { return false }
        state = .restoring
        origin = SetupOrigin(bundle)
        let preview = await setup.previewReceived(bundle)
        guard self.session === session, !session.isEnded else { return false }
        state = .choosing(preview)
        return true
    }

    /// The owner tapped the button: each difference is asked in turn, then what came is restored with the
    /// answers and the other device told it is done. Only while the other device still waits: once it left,
    /// nothing is restored.
    public func restoreChosen() async {
        guard case .choosing = state, let session, !session.isEnded else { return }
        guard await setup.askQuestions(), case .choosing = state, self.session === session, !session.isEnded,
            let channel = session.channel
        else { return }
        state = .restoring
        await restore(over: channel, in: session)
    }

    /// The other device left while the owner was asked: nothing was restored.
    private func left(_ session: DirectSession, _ error: SetupError) {
        guard case .choosing = state else { return }
        setup.endQuestions()
        failed(session, Self.failure(error))
    }

    private func restore(over channel: SetupChannel, in session: DirectSession) async {
        let report = await setup.restoreReceived() ?? SetupImportReport()
        // Restored whatever the other device does next: its answer does not change the report. Told before the
        // Contacts and notifications asks, so it does not wait on a prompt here.
        try? await channel.sendDone(restored: true)
        session.end(stop: false)
        let shown = self.session === session
        if shown {
            self.session = nil
            state = .report(report)
        }
        await setup.askAfterReceived { asked in
            if shown, case .report = self.state { self.state = .report(asked) }
        }
        // The accounts were added whatever this screen shows now: the app reads them.
        if report.changedAnything { await restored() }
    }

    private func end(_ session: DirectSession, stop: Bool = false) {
        session.end(stop: stop)
        if self.session === session { self.session = nil }
    }

    nonisolated static func failure(_ error: SetupError) -> Failure {
        switch error {
        case .handshakeFailed: .handshake
        case .stopped: .stopped
        case .unsupported: .newerVersion
        case .timedOut, .connectionLost, .malformed, .tooLarge, .wrongPassphrase, .unavailable: .lost
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// The device a setup came from, by the name it gave (cleaned; possibly ""), and when it was made there.
public struct SetupOrigin: Sendable, Equatable {
    public var device: String
    public var created: Date

    public init(device: String, created: Date) {
        self.device = device
        self.created = created
    }

    public init(_ bundle: SetupBundle) {
        self.init(device: bundle.shownDevice, created: bundle.created)
    }
}
