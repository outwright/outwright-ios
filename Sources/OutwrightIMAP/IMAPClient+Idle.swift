// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Where the IDLE of the current generation is.
enum IdleStage: Sendable {
    /// IDLE is sent and the server's `+` has not come.
    case starting
    /// The server is idling; DONE has not been sent.
    case waiting
    /// DONE is sent; the server's answer has not come.
    case ending
    case ended
}

/// IDLE (RFC 2177): waiting for the selected folder to change.
extension IMAPClient {
    static let idleCancelGrace: Duration = .seconds(2)

    /// What one IDLE may still take: the time until its deadline and the bytes left under the
    /// cap a command's responses have.
    private struct IdleBudget {
        var deadline: ContinuousClock.Instant
        var bytes = 0
    }

    /// Waits up to `timeout` for the selected folder to change. True when it did. Without IDLE
    /// on the server it waits out `timeout` and asks with NOOP. A cancelled task ends the wait
    /// at once (DONE is sent, or the wait for the connection is given up) and gets false unless
    /// a change came first. After a cancel the server has two seconds to start the IDLE (its
    /// `+`) and two more to end it after DONE; a DONE sent for a change or the timeout gets the
    /// usual wait for an answer. A server that misses one has the connection closed (it can't be
    /// brought back in step without the server) and the wait fails.
    public func idle(timeout: Duration) async throws(IMAPError) -> Bool {
        do {
            return try await idleTurn(timeout: timeout)
        } catch .cancelled {
            return false
        }
    }

    private func idleTurn(timeout: Duration) async throws(IMAPError) -> Bool {
        try await perform { () async throws(IMAPError) in
            guard capabilities.contains("IDLE") else {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return false
                }
                return try await run([.word("NOOP")]).untagged.contains(where: Self.isChange)
            }
            guard !Task.isCancelled else {
                return false
            }
            idleGeneration &+= 1
            let generation = idleGeneration
            // The cancel is for this IDLE only: by the time it runs, another may have begun.
            let result: Result<Bool, IMAPError> = await withTaskCancellationHandler {
                await idleResult(timeout: timeout, generation: generation)
            } onCancel: {
                Task { await self.cancelIdle(generation) }
            }
            return try result.get()
        }
    }

    private func idleResult(timeout: Duration, generation: Int) async -> Result<Bool, IMAPError> {
        do throws(IMAPError) {
            return .success(try await idleSession(timeout: timeout, generation: generation))
        } catch {
            return .failure(error)
        }
    }

    private func idleSession(timeout: Duration, generation: Int) async throws(IMAPError) -> Bool {
        idleStage = .starting
        defer { idleStage = .ended }
        let tag = nextTag()
        var budget = IdleBudget(deadline: .now + timing.response)
        try await write(Data("\(tag) IDLE\r\n".utf8))
        let changed = try await idleStarted(tag: tag, budget: &budget)
        idleStage = .waiting
        budget.deadline = .now + timeout + timing.idleGrace
        if changed || Task.isCancelled {
            await endIdle(generation, answerWithin: Task.isCancelled ? Self.idleCancelGrace : timing.perRead)
        }
        let perRead = timing.perRead
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else {
                return
            }
            await self?.endIdle(generation, answerWithin: perRead)
        }
        defer { timer.cancel() }
        return try await idleEnded(tag: tag, generation: generation, budget: &budget) || changed
    }

    /// One response within what the IDLE has left of its time and bytes.
    private func idleResponse(_ budget: inout IdleBudget) async throws(IMAPError) -> IMAPResponse {
        let left = budget.deadline - .now
        guard left > .zero else {
            throw .net(.timeout)
        }
        let (response, bytes) = try await readResponse(budget: left)
        budget.bytes = budget.bytes.saturatingAdd(bytes)
        guard budget.bytes <= timing.commandTotal else {
            throw .protocolViolation
        }
        return response
    }

    /// Waits for the `+` that starts IDLE; true when a change came before it.
    private func idleStarted(tag: String, budget: inout IdleBudget) async throws(IMAPError) -> Bool {
        var changed = false
        for _ in 0..<Self.maxUntagged {
            let response = try await idleResponse(&budget)
            switch response {
            case .continuation:
                return changed
            case let .status(responseTag?, kind, _, text) where responseTag == tag:
                throw Self.failure(kind, IMAPError.clamp(text))
            case .status(_?, _, _, _):
                throw .protocolViolation
            default:
                changed = changed || Self.isChange(response)
            }
        }
        throw .protocolViolation
    }

    /// Reads until IDLE ends, sending DONE at the first change; true when there was one.
    private func idleEnded(tag: String, generation: Int, budget: inout IdleBudget) async throws(IMAPError) -> Bool {
        var changed = false
        for _ in 0..<Self.maxUntagged {
            let response = try await idleResponse(&budget)
            switch response {
            case let .status(responseTag?, kind, _, text) where responseTag == tag:
                guard kind == .ok else {
                    throw Self.failure(kind, IMAPError.clamp(text))
                }
                return changed
            case .status(_?, _, _, _), .continuation:
                throw .protocolViolation
            default:
                if Self.isChange(response) {
                    changed = true
                    await endIdle(generation, answerWithin: timing.perRead)
                }
            }
        }
        throw .protocolViolation
    }

    /// A cancel of the IDLE of `generation`: DONE (if not sent already), answered within two
    /// seconds. Before the server's `+` (DONE follows it) the `+` gets two seconds; then the
    /// connection is closed. Nothing for an IDLE that has ended.
    private func cancelIdle(_ generation: Int) async {
        guard generation == idleGeneration else {
            return
        }
        switch idleStage {
        case .starting:
            try? await Task.sleep(for: Self.idleCancelGrace)
            if generation == idleGeneration, idleStage == .starting {
                await logoutWithoutCommand()
            }
        case .waiting:
            await endIdle(generation, answerWithin: Self.idleCancelGrace)
        case .ending:
            // DONE went before the cancel, with a longer wait for its answer.
            try? await Task.sleep(for: Self.idleCancelGrace)
            await giveUpIdle(generation)
        case .ended:
            return
        }
    }

    /// Sends DONE once for the IDLE of `generation`, and never for an IDLE that has ended. A
    /// server that has not ended the IDLE `answerWithin` later has its connection closed.
    private func endIdle(_ generation: Int, answerWithin wait: Duration) async {
        guard generation == idleGeneration, idleStage == .waiting else {
            return
        }
        idleStage = .ending
        try? await connection.write(Data("DONE\r\n".utf8))
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            await self?.giveUpIdle(generation)
        }
    }

    private func giveUpIdle(_ generation: Int) async {
        if generation == idleGeneration, idleStage == .ending {
            await logoutWithoutCommand()
        }
    }
}
