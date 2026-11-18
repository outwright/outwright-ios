// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Starts a direct transfer: the Noise handshake over a `SetupStream`, keyed by the pairing code's secret and bound to
/// the whole code. The device that scanned the code is the initiator; the one that shows it is the responder.
public enum SetupTransfer {
    /// A Noise handshake message: an ephemeral key and the tag of the empty payload.
    static let handshakeMessage = 48

    /// The handshake, within `handshakeTimeout`; then every send and receive on the channel within `timeout`. A side
    /// that holds another code ends it with `.handshakeFailed` on both sides: the responder answers a message that
    /// does not open with an empty frame before it closes.
    public static func connect(
        _ stream: any SetupStream, code: PairingCode, asInitiator: Bool,
        handshakeTimeout: Duration = .seconds(30), timeout: Duration = .seconds(300)
    ) async throws(SetupError) -> SetupChannel {
        let deadline = ContinuousClock.now.advanced(by: handshakeTimeout)
        do throws(SetupError) {
            var handshake = try NoiseHandshake(initiator: asInitiator, psk: code.secret, prologue: code.binary)
            if asInitiator {
                try await send(stream, frame(try handshake.writeMessage()), by: deadline)
                try handshake.readMessage(try await receiveHandshake(stream, by: deadline))
            } else {
                do throws(SetupError) {
                    try handshake.readMessage(try await receiveHandshake(stream, by: deadline))
                } catch {
                    if error == .handshakeFailed { try? await send(stream, Data([0, 0]), by: deadline) }
                    throw error
                }
                try await send(stream, frame(try handshake.writeMessage()), by: deadline)
            }
            return SetupChannel(stream: stream, transport: try handshake.split(), timeout: timeout)
        } catch {
            stream.close()
            throw error
        }
    }

    private static func send(
        _ stream: any SetupStream, _ data: Data, by deadline: ContinuousClock.Instant
    ) async throws(SetupError) {
        try await withDeadline(stream, by: deadline) { () async throws(SetupError) in try await stream.send(data) }
    }

    private static func frame(_ message: [UInt8]) -> Data {
        Data(SetupChannel.bigEndian(message.count, octets: 2) + message)
    }

    /// One handshake frame. Any length but a handshake message's (the empty refusal among them) fails the handshake
    /// before more is read.
    private static func receiveHandshake(
        _ stream: any SetupStream, by deadline: ContinuousClock.Instant
    ) async throws(SetupError) -> [UInt8] {
        let length = SetupChannel.integer([UInt8](try await receive(stream, exactly: 2, by: deadline)))
        guard length == handshakeMessage else { throw .handshakeFailed }
        return [UInt8](try await receive(stream, exactly: length, by: deadline))
    }

    /// Exactly `count` octets from the stream by `deadline`, else `.timedOut`.
    static func receive(
        _ stream: any SetupStream, exactly count: Int, by deadline: ContinuousClock.Instant
    ) async throws(SetupError) -> Data {
        let data = try await withDeadline(stream, by: deadline) { () async throws(SetupError) in
            try await stream.receive(exactly: count)
        }
        guard data.count == count else {
            stream.close()
            throw .connectionLost
        }
        return data
    }

    /// `body`'s result by `deadline`, else `.timedOut`. A failure closes the stream, so a read or write left waiting
    /// on it ends too.
    static func withDeadline<Value: Sendable>(
        _ stream: any SetupStream, by deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable () async throws(SetupError) -> Value
    ) async throws(SetupError) -> Value {
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw SetupError.timedOut
                }
                do {
                    guard let value = try await group.next() else { throw SetupError.connectionLost }
                    group.cancelAll()
                    return value
                } catch {
                    stream.close()
                    group.cancelAll()
                    throw error
                }
            }
        } catch let error as SetupError {
            throw error
        } catch {
            throw .connectionLost
        }
    }
}
