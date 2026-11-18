// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Synchronization

/// The link a direct transfer runs over: an ordered, reliable byte stream to the other device.
public protocol SetupStream: Sendable {
    func send(_ data: Data) async throws(SetupError)
    /// Exactly `count` octets, or `.connectionLost` when the stream ends first.
    func receive(exactly count: Int) async throws(SetupError) -> Data
    /// Ends the stream both ways; a send or receive waiting on it ends with `.connectionLost`.
    func close()
}

/// An established direct transfer: records over Noise transport messages over a `SetupStream`.
///
/// On the wire every Noise message is its length (2 octets, big-endian) and the message. A record is a message of
/// exactly five octets, `type(1) length(4, big-endian)`, then its payload in messages of 1 to 65 519 octets that add up
/// to the length. The header is checked (a known type, a length within its type's cap) before any payload is read.
/// Every receive times out (`done` only once the bundle went, `untilLeft` never); any failure ends the session, and
/// later calls throw the same error.
public actor SetupChannel {
    enum RecordType: UInt8 {
        case hello = 1
        case bundle = 2
        case done = 3
        case stop = 4

        var cap: Int {
            switch self {
            case .hello, .done: 4 * 1024
            case .bundle: SymmetricMessage.maximumSize
            case .stop: 0
            }
        }
    }

    static let headerSize = 5
    static let maxPlaintext = NoiseTransport.maxMessage - NoiseHandshake.tagSize

    private let stream: any SetupStream
    private var transport: NoiseTransport
    private let timeout: Duration
    private var ended: SetupError?
    /// The last write queued: each write starts when the one before it is through, so records reach the stream in
    /// the order they were sealed.
    private var lastWrite: Task<SetupError?, Never>?
    private var receiving = false
    /// Whether this side's bundle went out; until then a wait for `done` is not timed.
    private var bundleSent = false
    /// Starts the timer of a wait for `done` that began before the bundle went.
    private var onBundleSent: (@Sendable () -> Void)?

    init(stream: any SetupStream, transport: consuming NoiseTransport, timeout: Duration) {
        self.stream = stream
        self.transport = transport
        self.timeout = timeout
    }

    /// Ends the session and the stream under it.
    public nonisolated func close() {
        stream.close()
    }

    // MARK: Records

    private struct Hello: Codable { var device: String }
    private struct Done: Codable { var restored: Bool }

    /// The receiver's first record: its device name.
    public func sendHello(device: String) async throws(SetupError) {
        try await send(.hello, try Self.json(Hello(device: PairingCode.cut(device, to: PairingCode.maxDevice))))
    }

    /// The receiver's device name, cleaned of control and format characters and cut to `PairingCode.maxDevice`
    /// octets; possibly empty. Hostile.
    public func receiveHello() async throws(SetupError) -> String {
        let hello: Hello = try decoded(try await receive(.hello))
        return PairingCode.cut(PairingCode.cleaned(hello.device), to: PairingCode.maxDevice)
    }

    /// Sends the bundle; a wait for `done` is timed from when it went.
    public func sendBundle(_ bundle: SetupBundle) async throws(SetupError) {
        try await send(.bundle, try bundle.encoded())
        bundleSent = true
        onBundleSent?()
        onBundleSent = nil
    }

    /// The bundle the other side sent. One of a newer version throws `.unsupported` and leaves the session up, so
    /// this side can still say so with `sendStop`; any other failure ends it.
    public func receiveBundle() async throws(SetupError) -> SetupBundle {
        let json = try await receive(.bundle)
        do {
            return try SetupBundle.decoded(json)
        } catch {
            if error == .unsupported { throw error }
            throw finish(error)
        }
    }

    /// The receiver's last record: whether it restored the setup.
    public func sendDone(restored: Bool) async throws(SetupError) {
        try await send(.done, try Self.json(Done(restored: restored)))
    }

    /// The receiver's `done`. The sender may wait for it from before it sends the bundle, so the other side leaving
    /// (a `stop`, a dropped link) shows at once: the wait is timed only from when this side's bundle went.
    public func receiveDone() async throws(SetupError) -> Bool {
        let done: Done = try decoded(try await receive(.done, timing: .fromBundle))
        return done.restored
    }

    /// The receiver holding the bundle while its owner decides: waits, untimed, for the other side to leave and
    /// returns why (`.stopped` for a `stop`, a dropped link's error otherwise). Any record that comes meanwhile is out
    /// of order and ends the session. Closing the channel ends the wait.
    public func untilLeft() async -> SetupError {
        do throws(SetupError) {
            _ = try await receive(.stop, timing: .never)
            return .stopped
        } catch {
            return error
        }
    }

    /// Tells the other side the owner cancelled.
    public func sendStop() async throws(SetupError) {
        try await send(.stop, Data())
    }

    // MARK: Framing

    private func send(_ type: RecordType, _ payload: Data) async throws(SetupError) {
        guard payload.count <= type.cap else { throw .tooLarge }
        var messages: [[UInt8]] = [[type.rawValue] + Self.bigEndian(payload.count, octets: 4)]
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let next =
                payload.index(offset, offsetBy: Self.maxPlaintext, limitedBy: payload.endIndex) ?? payload.endIndex
            messages.append([UInt8](payload[offset..<next]))
            offset = next
        }
        try await send(messages: messages)
    }

    /// Seals the messages in order and queues them as one write after the writes before it, so another send never
    /// lands between them or ahead of them. A write that does not finish within the timeout ends the session.
    func send(messages: [[UInt8]]) async throws(SetupError) {
        if let ended { throw ended }
        var wire = Data()
        do throws(SetupError) {
            for message in messages {
                let sealed = try transport.seal(message)
                wire.append(contentsOf: Self.bigEndian(sealed.count, octets: 2))
                wire.append(contentsOf: sealed)
            }
        } catch {
            throw finish(error)
        }
        let previous = lastWrite
        let stream = stream
        let timeout = timeout
        let write = Task { [wire] () -> SetupError? in
            if let failed = await previous?.value { return failed }
            do throws(SetupError) {
                try await SetupTransfer.withDeadline(stream, by: ContinuousClock.now.advanced(by: timeout)) {
                    () async throws(SetupError) in try await stream.send(wire)
                }
                return nil
            } catch {
                return error
            }
        }
        lastWrite = write
        // A cancelled caller closes the stream, so the write ends and the session with it.
        let failure = await withTaskCancellationHandler {
            await write.value
        } onCancel: {
            stream.close()
        }
        if let failure { throw finish(failure) }
    }

    /// When a receive's time starts: now, when this side's bundle went, or never.
    private enum Timing {
        case now, fromBundle, never
    }

    /// The payload of the next record, which must be of `expected` type. A `stop` record throws `.stopped`. Timed
    /// as `timing` says.
    private func receive(_ expected: RecordType, timing: Timing = .now) async throws(SetupError) -> Data {
        if let ended { throw ended }
        // One receive at a time: two would take each other's messages.
        guard !receiving else { throw .malformed }
        receiving = true
        defer { receiving = false }
        let deadline = timing == .now ? ContinuousClock.now.advanced(by: timeout) : nil
        let watch = ReceiveWatch(stream)
        if timing == .fromBundle { timeFromBundle(watch) }
        defer {
            watch.cancel()
            onBundleSent = nil
        }
        do throws(SetupError) {
            let header = try await receiveMessage(by: deadline)
            guard header.count == Self.headerSize, let first = header.first, let type = RecordType(rawValue: first)
            else { throw SetupError.malformed }
            let length = Self.integer(header.dropFirst())
            guard length <= type.cap else { throw SetupError.malformed }
            if type == .stop { throw SetupError.stopped }
            guard type == expected else { throw SetupError.malformed }
            var payload = Data()
            while payload.count < length {
                let message = try await receiveMessage(by: deadline)
                guard !message.isEmpty, message.count <= length - payload.count else { throw SetupError.malformed }
                payload.append(contentsOf: message)
            }
            return payload
        } catch {
            throw finish(watch.expired ? .timedOut : error)
        }
    }

    /// Starts `watch` now when this side's bundle went, else when it goes.
    private func timeFromBundle(_ watch: ReceiveWatch) {
        let timeout = timeout
        if bundleSent {
            watch.start(timeout)
        } else {
            onBundleSent = { watch.start(timeout) }
        }
    }

    /// The next message, by `deadline`, or with none for as long as the stream lasts.
    private func receiveMessage(by deadline: ContinuousClock.Instant?) async throws(SetupError) -> [UInt8] {
        let length = Self.integer([UInt8](try await receive(exactly: 2, by: deadline)))
        let sealed = try await receive(exactly: length, by: deadline)
        return try transport.open([UInt8](sealed))
    }

    private func receive(exactly count: Int, by deadline: ContinuousClock.Instant?) async throws(SetupError) -> Data {
        if let deadline { return try await SetupTransfer.receive(stream, exactly: count, by: deadline) }
        let data = try await stream.receive(exactly: count)
        guard data.count == count else {
            stream.close()
            throw .connectionLost
        }
        return data
    }

    /// Ends the session on the first failure; every later call throws the same error.
    private func finish(_ error: SetupError) -> SetupError {
        if ended == nil {
            ended = error
            stream.close()
        }
        return ended ?? error
    }

    private static func json(_ value: some Encodable) throws(SetupError) -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw .malformed }
    }

    /// A record's JSON; one that does not decode ends the session.
    private func decoded<Value: Decodable>(_ json: Data) throws(SetupError) -> Value {
        do { return try JSONDecoder().decode(Value.self, from: json) } catch { throw finish(.malformed) }
    }

    static func bigEndian(_ value: Int, octets: Int) -> [UInt8] {
        (0..<octets).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// A big-endian integer of at most four octets.
    static func integer(_ octets: some Collection<UInt8>) -> Int {
        octets.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }
}

/// A receive's timer that starts later: once it runs out it closes the stream, which ends the receive, and says
/// it expired.
final class ReceiveWatch: Sendable {
    private let stream: any SetupStream
    private struct State {
        var timer: Task<Void, Never>?
        var expired = false
        var cancelled = false
    }

    private let state = Mutex(State())

    init(_ stream: any SetupStream) {
        self.stream = stream
    }

    var expired: Bool { state.withLock { $0.expired } }

    func start(_ timeout: Duration) {
        let stream = stream
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let expired = self.state.withLock { state -> Bool in
                guard !state.cancelled else { return false }
                state.expired = true
                return true
            }
            if expired { stream.close() }
        }
        let started = state.withLock { state -> Bool in
            guard !state.cancelled, state.timer == nil else { return false }
            state.timer = timer
            return true
        }
        if !started { timer.cancel() }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            return state.timer
        }?.cancel()
    }
}
