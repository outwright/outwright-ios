// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightSetup
import Synchronization

/// Two ends of an in-memory `SetupStream`, for testing a direct transfer without a network.
public enum SetupStreamPair {
    public static func make() -> (End, End) {
        let one = Pipe()
        let other = Pipe()
        return (End(inbound: one, outbound: other), End(inbound: other, outbound: one))
    }

    /// One end. `close()` cuts the stream both ways: what was already sent can still be read, then every receive
    /// ends with `.connectionLost`.
    public final class End: SetupStream {
        private let inbound: Pipe
        private let outbound: Pipe

        init(inbound: Pipe, outbound: Pipe) {
            self.inbound = inbound
            self.outbound = outbound
        }

        /// How many octets this end's receives have returned.
        public var bytesRead: Int { inbound.state.withLock { $0.read } }

        /// Stops this end reading, as a peer that hangs would: a send to it waits until the stream is closed.
        public func stopReading() {
            inbound.state.withLock { $0.stalled = true }
        }

        public func send(_ data: Data) async throws(SetupError) {
            while outbound.state.withLock({ $0.stalled && !$0.closed }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = outbound.state.withLock { state -> Bool in
                        if state.closed || !state.stalled { return true }
                        state.sendWaiters.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
            let waiter = try outbound.state.withLock { state throws(SetupError) -> CheckedContinuation<Void, Never>? in
                guard !state.closed else { throw .connectionLost }
                state.buffer.append(contentsOf: data)
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }

        public func receive(exactly count: Int) async throws(SetupError) -> Data {
            guard count >= 0 else { throw .malformed }
            while true {
                let outcome = inbound.state.withLock { state -> Data? in
                    guard state.buffer.count - state.start >= count else { return nil }
                    let data = Data(state.buffer[state.start..<(state.start + count)])
                    state.start += count
                    state.read += count
                    if state.start > 65_536, state.start * 2 > state.buffer.count {
                        state.buffer.removeFirst(state.start)
                        state.start = 0
                    }
                    return data
                }
                if let outcome { return outcome }
                if inbound.state.withLock({ $0.closed }) { throw .connectionLost }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = inbound.state.withLock { state -> Bool in
                        if state.closed || state.buffer.count - state.start >= count { return true }
                        state.waiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }

        public func close() {
            inbound.close()
            outbound.close()
        }
    }

    final class Pipe: Sendable {
        let state = Mutex(PipeState())

        func close() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.closed = true
                defer {
                    state.waiter = nil
                    state.sendWaiters = []
                }
                return [state.waiter].compactMap(\.self) + state.sendWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }
}

/// One direction of a `SetupStreamPair`: what was sent and not yet read, from `start`.
struct PipeState {
    var buffer: [UInt8] = []
    var start = 0
    var read = 0
    var closed = false
    /// The reading end has stopped reading: sends wait.
    var stalled = false
    /// A receive waiting for octets.
    var waiter: CheckedContinuation<Void, Never>?
    /// The sends waiting for a stalled reader.
    var sendWaiters: [CheckedContinuation<Void, Never>] = []
}
