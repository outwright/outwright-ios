// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore

/// What a run's folder changes have settled so far.
struct FolderRun {
    /// Queued actions already done with (dropped by the store when a refused create was undone).
    var settled: Set<Int64> = []
    /// Folders a change given up in this run acted in (a move out whose message wasn't found).
    var givenUpIn: Set<FolderID> = []
    /// Paths this run's delete has already deleted on the server.
    var deleted: Set<String> = []
    /// Folders whose change waits (the server can't now): what acts in them waits too.
    var stuck: Set<FolderID> = []
    /// Queued actions as the store has them now, after an undone create repointed them.
    var repointed: [Int64: PendingAction] = [:]
}
