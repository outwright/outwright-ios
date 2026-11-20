// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel

/// What each account last failed with, for the banner.
extension SyncCoordinator {
    /// Keeps what the account last failed with, for the banner. A first failure to reach the
    /// server in a row is passed over (the network may not be back yet when the app comes to the
    /// front, and the retry decides); from the second on it is kept.
    func record(_ id: AccountID, _ error: SyncError?) {
        guard let error else {
            lastErrors[id] = nil
            unreachableInARow[id] = nil
            return
        }
        syncLog.error("Sync failed: \(errorCode(error), privacy: .public)")
        // The store keeps it until the owner has seen it; it is no sync problem.
        if case .folderChangeRefused = error {
            lastErrors[id] = nil
            unreachableInARow[id] = nil
            return
        }
        if error.isUnreachable {
            let count = (unreachableInARow[id] ?? 0) + 1
            unreachableInARow[id] = count
            guard count > 1 else {
                return
            }
        } else {
            unreachableInARow[id] = nil
        }
        lastErrors[id] = error
    }

    /// Notes one protocol's sync of the account in the diagnostics journal, by its error's code
    /// (nil: it worked). Every failure is noted, the first unreachable one too; a run cut short
    /// (cancelled) tells nothing about the account and is not noted.
    func journalSync(_ id: AccountID, _ kind: SyncKind, _ error: SyncError?) {
        guard !Task.isCancelled, let journal else { return }
        let code = error.map(errorCode)
        let key = JournalKey(account: id, kind: kind)
        let date = now()
        // A watch that keeps failing the same way (a retry a minute) is noted once per quarter of
        // an hour, so it does not push everything else out of the journal.
        if let code, let last = journaled[key], last.code == code,
            date.timeIntervalSince(last.at) < Self.journalRepeat {
            return
        }
        journaled[key] = (code, date)
        journal.note(.sync(account: id, kind: kind, code: code))
    }

    /// How long a failure the same as the last one noted waits before it is noted again.
    static let journalRepeat: TimeInterval = 15 * 60
}

/// One account's protocol, for what it last noted in the journal.
struct JournalKey: Hashable {
    let account: AccountID
    let kind: SyncKind
}
