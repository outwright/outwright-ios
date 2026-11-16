// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os

/// Turns a stream task's read callback into one async answer. The stream task can call the
/// callback twice (its result, then "cancelled" when the connection closes; seen on iOS), which
/// the system's own async bridge traps on: here the first answer counts and later ones are
/// dropped.
enum StreamRead {
    typealias Answer = @Sendable (Data?, Bool, (any Error)?) -> Void

    static func once(_ start: (@escaping Answer) -> Void) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            start { data, atEnd, error in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else {
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, atEnd))
                }
            }
        }
    }
}

/// The same for a write: the stream task may answer it twice too; the first answer counts.
enum StreamWrite {
    typealias Answer = @Sendable ((any Error)?) -> Void

    static func once(_ start: (@escaping Answer) -> Void) async throws {
        let _: (Data?, Bool) = try await StreamRead.once { answer in
            start { error in answer(nil, false, error) }
        }
    }
}
