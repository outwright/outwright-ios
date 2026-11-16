// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// One account's turn to talk to its server: shared by every syncer the account has had, so
/// a syncer that replaces another waits for the old one's operation to end.
actor AccountLock {
    private var busy = false
    private var waiters: [(id: Int, turn: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter = 0

    /// Waits for the turn; false, without the turn, when the task is cancelled before it comes.
    func acquire() async -> Bool {
        guard busy else {
            busy = true
            return true
        }
        guard !Task.isCancelled else {
            return false
        }
        let id = nextWaiter
        nextWaiter &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    /// Hands the turn to the next in line, or frees it.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().turn.resume(returning: true)
        }
    }

    private func giveUp(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).turn.resume(returning: false)
    }
}
