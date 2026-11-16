// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore

extension MailStore {
    /// A folder by id, from any account; nil when it is gone or the store fails.
    func findFolder(_ id: FolderID) -> Folder? {
        guard let accounts = try? accounts() else { return nil }
        for account in accounts {
            if let found = (try? folders(account.id))?.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }
}
