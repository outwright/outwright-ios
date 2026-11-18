// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

@testable import OutwrightStore

extension MailStore {
    /// While on, the database refuses to queue an action for the server, as a full disk would.
    func refuseQueuedActions(_ refuse: Bool) throws {
        try write { database in
            if refuse {
                try database.execute(
                    sql: """
                        CREATE TRIGGER refuse_queue BEFORE INSERT ON pending_action
                        BEGIN SELECT RAISE(ABORT, 'refused'); END
                        """)
            } else {
                try database.execute(sql: "DROP TRIGGER IF EXISTS refuse_queue")
            }
        }
    }

    /// Makes the subscribed calendars unreadable, as a damaged database would.
    func breakSubscriptions() throws {
        try write { database in
            try database.execute(sql: "ALTER TABLE calendar_subscription RENAME TO calendar_subscription_gone")
        }
    }

    /// The accounts can no longer be read, as a damaged or locked database would.
    func breakAccountReads() throws {
        try write { database in try database.execute(sql: "ALTER TABLE account RENAME TO account_unreadable") }
    }

    /// The account kim@example.org can no longer be changed, as a refusing database would.
    func refuseChangesToKim() throws {
        try write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER refuse_account BEFORE UPDATE ON account WHEN OLD.email = 'kim@example.org'
                    BEGIN SELECT RAISE(ABORT, 'refused'); END
                    """)
        }
    }
}
