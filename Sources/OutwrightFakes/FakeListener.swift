// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Network
import Synchronization

/// Why a fake could not start.
public enum FakeError: Error, Sendable {
    case cannotListen(String)
}

/// A plain TCP listener on 127.0.0.1 (or another local address a test names) and a port the
/// system chooses, for the fake servers.
/// Each accepted connection is handed to `handler` on a task of its own.
public final class FakeListener: Sendable {
    private let listener = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "outwright.fake.listener")
    private let handler: @Sendable (FakeConnection) async -> Void
    private let host: String
    private let port: UInt16

    /// `host` is the local address to listen on (loopback unless a test needs a container to
    /// reach it); `port` 0 lets the system choose.
    public init(
        host: String = "127.0.0.1", port: UInt16 = 0, handler: @escaping @Sendable (FakeConnection) async -> Void
    ) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let local = NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: local)
        let listener = try NWListener(using: parameters)
        self.listener.withLock { $0 = listener }
        let handler = self.handler
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            let fake = FakeConnection(connection, queue: queue)
            Task { await handler(fake) }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case let .failed(error):
                    if resumed.claim() {
                        continuation.resume(throwing: FakeError.cannotListen("\(error)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: FakeError.cannotListen("cancelled"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.withLock { $0?.cancel() }
    }
}

/// One accepted connection: lines and counted bytes in, bytes out.
public actor FakeConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var ended = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
    }

    /// The next line without its CR LF, or nil when the client has gone.
    public func readLine(maxBytes: Int = 1 << 20) async -> Data? {
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<end]
                if line.last == UInt8(ascii: "\r") {
                    line = line.dropLast()
                }
                buffer = Data(buffer[(end + 1)...])
                return Data(line)
            }
            guard buffer.count <= maxBytes, await receive() else {
                return nil
            }
        }
    }

    /// Exactly `count` bytes, or nil when the client has gone first.
    public func read(exactly count: Int) async -> Data? {
        while buffer.count < count {
            guard await receive() else {
                return nil
            }
        }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    /// Queues bytes to send; sends keep their order.
    public nonisolated func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public nonisolated func close() {
        let done = NWConnection.SendCompletion.contentProcessed { [connection] _ in
            connection.cancel()
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: done)
    }

    private func receive() async -> Bool {
        guard !ended else {
            return false
        }
        let connection = self.connection
        let (data, done) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool), Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete || error != nil))
            }
        }
        if let data, !data.isEmpty {
            buffer.append(data)
            if done {
                ended = true
            }
            return true
        }
        ended = ended || done
        return !done
    }
}

/// A flag that can be claimed once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed {
            return false
        }
        claimed = true
        return true
    }
}
