// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Network
import Synchronization

/// The device that shows the code: listens for the one device that scans it, advertised with Bonjour as
/// `_outwright-setup._tcp` under the code's service name.
public final class SetupListener: Sendable {
    private let service: String
    private let advertised: Bool
    private let queue = DispatchQueue(label: "outwright.setup.listener")
    private let state = Mutex(State())
    private let accepted = Outcome<any SetupStream>()

    private struct State {
        var listener: NWListener?
        var taken = false
        var stopped = false
    }

    /// `advertised: false` listens on loopback only and is not advertised, for tests.
    public init(service: String, advertised: Bool = true) {
        self.service = service
        self.advertised = advertised
    }

    /// Starts listening and returns the port. A listener the system holds back (on iOS while the local network
    /// prompt is up) is waited for until `within`, then `.timedOut`.
    public func start(within: Duration = .seconds(30)) async throws(SetupError) -> UInt16 {
        let listener = try makeListener()
        let fresh = state.withLock { state -> Bool in
            guard state.listener == nil, !state.stopped else { return false }
            state.listener = listener
            return true
        }
        guard fresh else { throw .connectionLost }
        let ready = Outcome<UInt16>()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if let outcome = Self.startOutcome(of: state, port: listener?.port?.rawValue ?? 0) {
                ready.resolve(outcome)
            }
            switch state {
            case .failed, .cancelled: self?.ended()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.take(connection)
        }
        listener.start(queue: queue)
        do throws(SetupError) {
            return try await SetupLink.deadline(within) { () async throws(SetupError) -> UInt16 in
                let port = await withTaskCancellationHandler {
                    await ready.value()
                } onCancel: {
                    ready.resolve(.failure(.connectionLost))
                }
                return try port.get()
            }
        } catch {
            stop()
            throw error
        }
    }

    /// What a listener's state means for `start`: nil while it is still to be waited for, `.waiting` included.
    static func startOutcome(of state: NWListener.State, port: UInt16) -> Result<UInt16, SetupError>? {
        switch state {
        case .ready where port != 0: .success(port)
        case .ready, .failed, .cancelled: .failure(.connectionLost)
        default: nil
        }
    }

    /// The one device that connected, or `.timedOut` when none came `within` the code's life, or `.connectionLost`
    /// when the system ended the listener first. Listening and advertising stop at the first connection; a later one
    /// is cancelled. A cancelled caller stops the listener.
    public func accept(within: Duration = .seconds(300)) async throws(SetupError) -> any SetupStream {
        let accepted = accepted
        let timer = Task { [weak self] in
            try? await Task.sleep(for: within)
            guard !Task.isCancelled else { return }
            if accepted.resolve(.failure(.timedOut)) { self?.stop() }
        }
        defer { timer.cancel() }
        let result = await withTaskCancellationHandler {
            await accepted.value()
        } onCancel: { [weak self] in
            self?.stop()
        }
        return try result.get()
    }

    /// Stops listening and advertising; an `accept` waiting ends with `.connectionLost`. A link already handed to
    /// `accept` stays open.
    public func stop() {
        let listener = state.withLock { state -> NWListener? in
            state.stopped = true
            defer { state.listener = nil }
            return state.listener
        }
        listener?.cancel()
        if let unclaimed = accepted.abandon(with: .connectionLost) { unclaimed.close() }
    }

    deinit {
        stop()
    }

    /// The system ended the listener (iOS does when the app is suspended): an `accept` waiting ends with
    /// `.connectionLost` at once instead of when the code runs out. A listener `take` or `stop` cancelled ends
    /// nothing more: `take` marks itself before it cancels, on the same queue as this.
    private func ended() {
        let unexpected = state.withLock { !$0.taken && !$0.stopped }
        if unexpected { stop() }
    }

    /// The system's listener while listening, for tests that end it as the system does.
    var underlying: NWListener? { state.withLock { $0.listener } }

    private func makeListener() throws(SetupError) -> NWListener {
        let parameters = SetupLink.parameters()
        if !advertised {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        }
        do {
            let listener = try NWListener(using: parameters)
            if advertised { listener.service = NWListener.Service(name: service, type: SetupLink.serviceType) }
            return listener
        } catch {
            throw .connectionLost
        }
    }

    private func take(_ connection: NWConnection) {
        let first = state.withLock { state -> Bool in
            guard !state.taken, !state.stopped else { return false }
            state.taken = true
            return true
        }
        guard first else {
            connection.cancel()
            return
        }
        // One connection only: stop listening and advertising, but keep the state for `stop()`.
        state.withLock { $0.listener }?.cancel()
        let accepted = accepted
        Task {
            let link = SetupLink(connection, failOnWaiting: true)
            do throws(SetupError) {
                try await link.open()
                if !accepted.resolve(.success(link)) { link.close() }
            } catch {
                accepted.resolve(.failure(error))
            }
        }
    }
}

/// An `NWConnection` as a `SetupStream`. A connection that fails or is cancelled ends every pending send and receive
/// with `.connectionLost`.
final class SetupLink: SetupStream {
    static let serviceType = "_outwright-setup._tcp"
    /// The most one receive may ask for: the largest frame the channel reads, a length and a Noise message.
    static let maxReceive = 2 + 65_535
    /// How long a closed link waits for what was sent before it to go out, before it is cut regardless.
    static let flushGrace: DispatchTimeInterval = .seconds(5)

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "outwright.setup.link")
    private let failOnWaiting: Bool
    private let ready = Outcome<Void>()
    private let state = Mutex(State())

    private struct State {
        var closed = false
        var next = 0
        /// Every send and receive in flight, by number: ends it with an error.
        var pending: [Int: @Sendable (SetupError) -> Void] = [:]
    }

    /// `body`'s result, or `.timedOut` when it is not done `within`: then it is cancelled and its failure reported
    /// as the timeout. A cancelled caller cancels it.
    static func deadline<Value: Sendable>(
        _ within: Duration, _ body: @escaping @Sendable () async throws(SetupError) -> Value
    ) async throws(SetupError) -> Value {
        let expired = Mutex(false)
        let work = Task { () async -> Result<Value, SetupError> in
            do throws(SetupError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: within)
            guard !Task.isCancelled else { return }
            expired.withLock { $0 = true }
            work.cancel()
        }
        defer { timer.cancel() }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        switch result {
        case let .success(value): return value
        case let .failure(error): throw expired.withLock { $0 } ? .timedOut : error
        }
    }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    /// `failOnWaiting`: a connection the system cannot make right now fails at once instead of waiting for a path.
    init(_ connection: NWConnection, failOnWaiting: Bool) {
        self.connection = connection
        self.failOnWaiting = failOnWaiting
    }

    /// Starts the connection and waits until it is ready. A cancelled caller cancels it.
    func open() async throws(SetupError) {
        let ready = ready
        let failOnWaiting = failOnWaiting
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.resolve(.success(()))
            case .waiting:
                if failOnWaiting { self?.lose() }
            case .failed, .cancelled:
                self?.lose()
            default:
                break
            }
        }
        connection.start(queue: queue)
        let result = await withTaskCancellationHandler {
            await ready.value()
        } onCancel: {
            ready.resolve(.failure(.connectionLost))
        }
        do {
            try result.get()
        } catch {
            lose()
            throw error
        }
    }

    deinit {
        close()
    }

    /// The connection is gone or will not come: everything pending ends and the connection is let go.
    private func lose() {
        end()
        connection.cancel()
    }

    func send(_ data: Data) async throws(SetupError) {
        let sent = Outcome<Void>()
        guard let id = register(sent) else { throw .connectionLost }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                sent.resolve(error == nil ? .success(()) : .failure(.connectionLost))
                self?.unregister(id)
            })
        try await wait(sent)
    }

    func receive(exactly count: Int) async throws(SetupError) -> Data {
        guard count >= 0, count <= Self.maxReceive else { throw .malformed }
        var data = Data()
        while data.count < count {
            let wanted = count - data.count
            let received = Outcome<Data>()
            guard let id = register(received) else { throw .connectionLost }
            connection.receive(minimumIncompleteLength: 1, maximumLength: wanted) { [weak self] content, _, _, _ in
                // Octets that came with the end or an error still count; the next receive sees the end.
                if let content, !content.isEmpty, content.count <= wanted {
                    received.resolve(.success(content))
                } else {
                    received.resolve(.failure(.connectionLost))
                }
                self?.unregister(id)
            }
            data.append(try await wait(received))
        }
        return data
    }

    /// Ends every pending send and receive with `.connectionLost`, lets what was already sent go out, then cuts
    /// the connection.
    func close() {
        guard end() else { return }
        let connection = connection
        connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
        // A peer that stopped reading must not keep the connection forever.
        queue.asyncAfter(deadline: .now() + Self.flushGrace) { connection.cancel() }
    }

    /// Marks the link closed and fails everything pending; false when it already was.
    @discardableResult
    private func end() -> Bool {
        let failures = state.withLock { state -> [@Sendable (SetupError) -> Void]? in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        guard let failures else { return false }
        ready.resolve(.failure(.connectionLost))
        for fail in failures { fail(.connectionLost) }
        return true
    }

    private func register<Value>(_ outcome: Outcome<Value>) -> Int? {
        state.withLock { state -> Int? in
            guard !state.closed else { return nil }
            let id = state.next
            state.next = id &+ 1
            state.pending[id] = { error in outcome.resolve(.failure(error)) }
            return id
        }
    }

    private func unregister(_ id: Int) {
        state.withLock { _ = $0.pending.removeValue(forKey: id) }
    }

    /// The outcome; a cancelled caller closes the link, since a half-done read or write leaves it unusable.
    private func wait<Value>(_ outcome: Outcome<Value>) async throws(SetupError) -> Value {
        let result = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: { [weak self] in
            outcome.resolve(.failure(.connectionLost))
            self?.close()
        }
        return try result.get()
    }
}
