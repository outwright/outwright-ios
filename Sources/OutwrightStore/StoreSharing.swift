// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// When the app lets go of the store it shares with its notification extension. iOS kills a
/// suspended app that holds a lock on a shared file, so the stores are suspended
/// (`MailStore.suspendSharing`) whenever the app may be frozen: when the grace iOS gives after
/// going to the background runs out (not before: a draft saved, a send recorded or a sync
/// finishing in it still writes), at once when no grace is given, and when a background refresh
/// ends or is cut short. In front, while refreshing and in the grace, the stores are open.
@MainActor
public final class StoreSharing {
    /// Begins a grace period (a background task): `expired` runs when iOS ends it. Answers how to
    /// end it early, or nil when none is given.
    public typealias Grace = (_ expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

    private let beginGrace: Grace
    private nonisolated let suspend: @Sendable () -> Void
    private let resume: @Sendable () -> Void
    private var inFront = false
    private var refreshes = 0
    private var endGrace: (@MainActor () -> Void)?

    public init(
        beginGrace: @escaping Grace, suspend: @escaping @Sendable () -> Void = { MailStore.suspendSharing() },
        resume: @escaping @Sendable () -> Void = { MailStore.resumeSharing() }
    ) {
        self.beginGrace = beginGrace
        self.suspend = suspend
        self.resume = resume
    }

    public func cameToFront() {
        endTheGrace()
        inFront = true
        apply()
    }

    public func wentToBackground() {
        inFront = false
        endTheGrace()
        endGrace = beginGrace { [weak self] in
            self?.endTheGrace()
            self?.apply()
        }
        apply()
    }

    /// `body` (a background refresh) with the stores open; cut short, they are let go at once.
    public func refresh(_ body: @MainActor () async -> Void) async {
        refreshes += 1
        apply()
        let suspend = suspend
        await withTaskCancellationHandler {
            await body()
        } onCancel: {
            suspend()
        }
        refreshes -= 1
        apply()
    }

    private func endTheGrace() {
        let end = endGrace
        endGrace = nil
        end?()
    }

    private func apply() {
        if inFront || refreshes > 0 || endGrace != nil {
            resume()
        } else {
            suspend()
        }
    }
}
