// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Said in place of the text of a message that was opened from its protection but could not be read.
struct UnreadableNote: View {
    var body: some View {
        Text(ui: "This encrypted message could not be read")
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 16)
    }
}
