// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
public import OutwrightStore

/// What wants to know when the staged mail changes (a list or a conversation leaves out its rows).
@MainActor protocol PendingMailWatcher: AnyObject {
    func pendingMailChanged()
}

/// Undo as a deferred commit: a move or delete waits out the undo window before it reaches the store,
/// and meanwhile the rows it is about are left out of the lists. Undo drops it, so nothing is reversed.
/// A batch is committed when the window ends, when another is staged, and when the app goes to the background.
@Observable @MainActor
public final class PendingMail {
    public struct Batch: Identifiable, Sendable {
        public let id: UUID
        public let actions: [MailAction]
        public let hidden: Set<MessageID>
        /// What the undo toast says, in the interface's language.
        public let text: String
    }

    public private(set) var current: Batch?
    /// The last commit failed in the store; cleared when a batch is undone, or staged after a commit
    /// that worked.
    public private(set) var failed = false
    public static let window: Duration = .seconds(5)

    @ObservationIgnored let store: MailStore
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void
    /// The wait for the current batch's window to end.
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored private var watchers: [WeakWatcher] = []

    /// `sleep` waits out the window (a test gives its own).
    public init(
        store: MailStore, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.sleep = sleep
    }

    /// The messages left out of the lists now.
    public var hidden: Set<MessageID> { current?.hidden ?? [] }

    /// Stages `actions`, committing any earlier batch first; that batch's failure stays shown.
    public func stage(_ actions: [MailAction], hiding: Set<MessageID>, text: String) {
        failed = false
        commitNow(notifying: false)
        let batch = Batch(id: UUID(), actions: actions, hidden: hiding, text: text)
        current = batch
        let sleep = sleep
        let window = Self.window
        timer = Task { [weak self] in
            do {
                try await sleep(window)
            } catch {
                return
            }
            guard let self, self.current?.id == batch.id else { return }
            self.commitNow()
        }
        notify()
    }

    /// Drops the batch: its rows come back as they were.
    public func undo() {
        guard current != nil else { return }
        timer?.cancel()
        timer = nil
        current = nil
        failed = false
        notify()
    }

    /// Hands the batch to the store now.
    public func commit() async {
        commitNow()
    }

    /// Hands the batch to the store at once (the app is going to the background and may be suspended).
    func commitNow(notifying: Bool = true) {
        guard let batch = current else { return }
        timer?.cancel()
        timer = nil
        // A message that went meanwhile (expunged, its account removed) has nothing left to change.
        var broke = false
        for action in batch.actions {
            do {
                try store.apply(action)
            } catch .noSuchMessage {
                continue
            } catch {
                broke = true
            }
        }
        failed = broke
        current = nil
        if notifying { notify() }
    }

    func watch(_ watcher: some PendingMailWatcher) {
        watchers.removeAll { $0.watcher == nil }
        watchers.append(WeakWatcher(watcher: watcher))
    }

    private func notify() {
        watchers.removeAll { $0.watcher == nil }
        for entry in watchers {
            entry.watcher?.pendingMailChanged()
        }
    }

    private struct WeakWatcher {
        weak var watcher: (any PendingMailWatcher)?
    }
}
