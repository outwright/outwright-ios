// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// Where an account's password may go over CalDAV and CardDAV: the DAV address's own host and the
/// account's mail hosts, never a host a redirect names. One rule for sync and for the check at Connect.
enum DAVTrust {
    static func hosts(for context: URL, of account: Account) -> Set<String> {
        var hosts: Set<String> = [account.imap.host, account.smtp.host]
        if let host = context.host() { hosts.insert(host) }
        return hosts
    }
}
