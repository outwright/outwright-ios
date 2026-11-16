// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

extension MessageRow {
    /// The preview as the lists show it: a protected message not opened, with no preview, says so
    /// in the owner's language.
    func shownPreview(locale: Locale? = nil) -> String {
        guard isProtected, !isDecrypted, preview.isEmpty else { return preview }
        return locale.map { L10n.string("Encrypted message", locale: $0) } ?? L10n.string("Encrypted message")
    }
}
