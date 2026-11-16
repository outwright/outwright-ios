// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
public import OutwrightStore

extension SyncCoordinator {
    private struct Target {
        let syncer: AccountSyncer
        let account: AccountID
        let folder: FolderID
    }

    /// What a list shows: the folder, or every account's Inbox.
    private func targets(_ scope: InboxScope) async -> [Target] {
        var targets: [Target] = []
        for (id, syncer) in await currentSyncers() {
            let folders = (try? store.folders(id)) ?? []
            switch scope {
            case .allAccounts:
                if let inbox = folders.first(where: { $0.kind == .inbox }) {
                    targets.append(Target(syncer: syncer, account: id, folder: inbox.id))
                }
            case .folder(let wanted):
                if folders.contains(where: { $0.id == wanted }) {
                    targets.append(Target(syncer: syncer, account: id, folder: wanted))
                }
            }
        }
        return targets
    }

    /// A pull on the list: what it shows is brought in step, the accounts at once, and nothing
    /// else, so the pull ends quickly. Each account's error, or its success, is recorded.
    public func refreshShown(_ scope: InboxScope) async {
        let targets = await targets(scope)
        await withTaskGroup(of: (AccountID, SyncError?).self) { group in
            for target in targets {
                group.addTask {
                    do throws(SyncError) {
                        try await target.syncer.sync(target.folder)
                        return (target.account, nil)
                    } catch {
                        return (target.account, error)
                    }
                }
            }
            for await (id, error) in group where !Task.isCancelled {
                record(id, error)
            }
        }
    }

    /// Older mail for the list in view: the folder, or every account's Inbox. Returns whether
    /// any of them may have more; an account that fails is said to (the next try asks again),
    /// and its error is recorded.
    public func fetchOlder(_ scope: InboxScope, atLeast: Int) async -> Bool {
        let targets = await targets(scope)
        var more = false
        for target in targets {
            do {
                more = try await target.syncer.fetchOlder(target.folder, atLeast: atLeast) || more
            } catch {
                record(target.account, error)
                more = true
            }
        }
        return more
    }
}
