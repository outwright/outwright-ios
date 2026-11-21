// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
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

    /// One account's pull: its error, nil when it worked.
    private struct ShownAnswer: Sendable {
        let account: AccountID
        let error: SyncError?
    }

    /// A pull on the list: what it shows is brought in step, the accounts at once, and nothing
    /// else, so the pull ends quickly. Each account's error, or its success, is recorded. A child
    /// answers a named struct built once, never a tuple returned from both a `do` and its `catch`
    /// (swiftlang/swift#92698: optimized builds lose it and free the group under a running child).
    public func refreshShown(_ scope: InboxScope) async {
        let targets = await targets(scope)
        await withTaskGroup(of: ShownAnswer.self) { group in
            for target in targets {
                group.addTask {
                    var failure: SyncError?
                    do throws(SyncError) {
                        try await target.syncer.sync(target.folder)
                    } catch {
                        failure = error
                    }
                    return ShownAnswer(account: target.account, error: failure)
                }
            }
            for await answer in group where !Task.isCancelled {
                record(answer.account, answer.error)
                if scope == .allAccounts { inboxWasFetched(answer.account) }
            }
        }
    }

    /// The account's Inbox has been looked at, whether or not the server answered.
    func inboxWasFetched(_ id: AccountID) {
        inboxFetched.insert(id)
    }

    /// The accounts this build syncs whose Inbox has not been looked at yet: their empty list is mail on
    /// its way. An account of a provider the build does not carry is never synced, so never among them.
    public func awaitingFirstInbox() -> Set<AccountID> {
        let synced = (try? store.accounts().filter(isAvailable)) ?? []
        return Set(synced.map(\.id)).subtracting(inboxFetched)
    }

    /// Older mail for the list in view: the folder, or every account's Inbox. More when any of
    /// them may have more; failed when none of those asked could be, and every one that fails
    /// has its error recorded.
    public func fetchOlder(_ scope: InboxScope, atLeast: Int) async -> OlderMail {
        let targets = await targets(scope)
        var more = false
        var failed = false
        for target in targets {
            do {
                more = try await target.syncer.fetchOlder(target.folder, atLeast: atLeast) || more
            } catch {
                record(target.account, error)
                failed = true
            }
        }
        return more ? .more : failed ? .failed : .noneLeft
    }
}
