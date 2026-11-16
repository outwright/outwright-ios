// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// A message in Junk: its links and pictures are turned off, with Not junk.
struct JunkBar: View {
    let notJunk: () -> Void

    var body: some View {
        HStack {
            Image(systemName: Icons.junk)
                .foregroundStyle(Theme.secondaryText)
            Text(ui: "This message is in Junk. Its links and pictures are turned off.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(action: notJunk) {
                Text(ui: "Not junk").font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("reading.notJunk")
            .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.separator.opacity(0.5)))
    }
}

/// "Pictures are not downloaded" with Download pictures.
struct PicturesBar: View {
    let allow: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(Theme.secondaryText)
            Text(ui: "Pictures are not downloaded.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(action: allow) {
                Text(ui: "Download pictures").font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("reading.downloadPictures")
            .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.separator.opacity(0.5)))
    }
}
