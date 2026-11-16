// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// What the coordinator does to a syncer when its account changes.
extension AccountSyncer {
    /// The same account under a new display name: nothing to reconnect for.
    func update(_ account: Account) {
        self.account = account
    }

    /// Stops for good, at once: the operation under way fails at its next server call and is
    /// not run again, none follows, and nothing waits for a server that stopped answering.
    func retire() async {
        retired = true
        generation &+= 1
        let clients = [main, idler].compactMap { $0 }
        main = nil
        idler = nil
        for client in clients {
            await client.close()
        }
    }

    /// Whether an operation begun at `opened` may still go on.
    func isCurrent(_ opened: Int) -> Bool {
        !retired && generation == opened
    }
}
