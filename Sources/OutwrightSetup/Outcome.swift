// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Synchronization

/// A result set once, from any thread, and taken once: the first `resolve` wins, later ones are ignored.
final class Outcome<Value: Sendable>: Sendable {
    private enum State {
        case open
        case waiting(CheckedContinuation<Result<Value, SetupError>, Never>)
        case resolved(Result<Value, SetupError>)
        case taken
    }

    private let state = Mutex(State.open)

    /// False when the outcome was already set.
    @discardableResult
    func resolve(_ result: Result<Value, SetupError>) -> Bool {
        let waiter = state.withLock { state -> CheckedContinuation<Result<Value, SetupError>, Never>?? in
            switch state {
            case .open:
                state = .resolved(result)
                return .some(nil)
            case let .waiting(continuation):
                state = .taken
                return .some(continuation)
            case .resolved, .taken:
                return nil
            }
        }
        guard let waiter else { return false }
        waiter?.resume(returning: result)
        return true
    }

    /// Fails the outcome if nobody has it yet; a value set but not taken is handed back so it can be released.
    func abandon(with error: SetupError) -> Value? {
        let unclaimed = state.withLock { state -> Value? in
            if case let .resolved(.success(value)) = state {
                state = .resolved(.failure(error))
                return value
            }
            return nil
        }
        if unclaimed == nil { resolve(.failure(error)) }
        return unclaimed
    }

    /// The outcome once set. Only one caller takes it; a second gets `.connectionLost`.
    func value() async -> Result<Value, SetupError> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, SetupError>, Never>) in
            let ready = state.withLock { state -> Result<Value, SetupError>? in
                switch state {
                case .open:
                    state = .waiting(continuation)
                    return nil
                case let .resolved(result):
                    state = .taken
                    return result
                case .waiting, .taken:
                    return .failure(.connectionLost)
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
