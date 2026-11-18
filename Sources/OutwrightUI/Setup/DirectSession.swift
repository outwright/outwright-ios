// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSetup
import Synchronization

/// One direct transfer as far as it has come: the link, the channel over it and the work in flight. Ending it closes
/// all of them, whatever step it is at.
final class DirectSession: Sendable {
    private struct Held {
        var stream: (any SetupStream)?
        var channel: SetupChannel?
        var cancelWork: (@Sendable () -> Void)?
        var ended = false
    }

    private let held = Mutex(Held())

    var isEnded: Bool { held.withLock { $0.ended } }
    var channel: SetupChannel? { held.withLock { $0.channel } }

    /// The work in flight, cancelled when the session ends; at once when it has.
    func run(cancel: @escaping @Sendable () -> Void) {
        let ended = held.withLock { held -> Bool in
            if !held.ended { held.cancelWork = cancel }
            return held.ended
        }
        if ended { cancel() }
    }

    /// From here closing the link ends the work in flight (a receive waiting on it): the end leaves it uncancelled,
    /// since cancelling a receive closes the link before a stop could go out.
    func linkEndsWork() {
        held.withLock { $0.cancelWork = nil }
    }

    /// Keeps the stream for the end to close; false (and the stream closed) when the session already ended.
    func hold(_ stream: any SetupStream) -> Bool {
        let kept = held.withLock { held -> Bool in
            if !held.ended { held.stream = stream }
            return !held.ended
        }
        if !kept { stream.close() }
        return kept
    }

    /// Keeps the channel for the end to close; false (and the channel closed) when the session already ended.
    func hold(_ channel: SetupChannel) -> Bool {
        let kept = held.withLock { held -> Bool in
            if !held.ended { held.channel = channel }
            return !held.ended
        }
        if !kept { channel.close() }
        return kept
    }

    /// Ends the session once: the work in flight is cancelled at once. With `stop` and a channel, the other device is
    /// told, given `grace` for it to go out; then the link closes.
    func end(stop: Bool, grace: Duration = .seconds(2)) {
        let taken = held.withLock { held -> Held? in
            guard !held.ended else { return nil }
            defer { held = Held(ended: true) }
            return held
        }
        guard let taken else { return }
        taken.cancelWork?()
        guard stop, let channel = taken.channel else {
            taken.channel?.close()
            taken.stream?.close()
            return
        }
        Task.detached {
            let closer = Task {
                try? await Task.sleep(for: grace)
                channel.close()
            }
            try? await channel.sendStop()
            closer.cancel()
            channel.close()
            taken.stream?.close()
        }
    }
}
