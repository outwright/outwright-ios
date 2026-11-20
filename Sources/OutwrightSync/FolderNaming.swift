// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightIMAP

/// A folder name as the owner types it, and as the server writes it.
public enum FolderNaming {
    /// The name in the server's form (modified UTF-7, RFC 3501 §5.1.3).
    public static func wire(_ name: String) -> String {
        ModifiedUTF7.encode(name)
    }
}
