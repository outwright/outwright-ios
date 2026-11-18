// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// A note over the body with its button beside it, or under it at the largest text sizes.
private struct NoteLayout<Note: View, Action: View>: View {
    @ViewBuilder let note: () -> Note
    @ViewBuilder let action: () -> Action
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                note()
                action()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                note()
                Spacer()
                action()
            }
        }
    }
}

/// A message in Junk: its links and pictures are turned off, with Not junk.
struct JunkBar: View {
    let notJunk: () -> Void

    var body: some View {
        NoteLayout {
            HStack {
                Image(systemName: Icons.junk)
                    .foregroundStyle(Theme.secondaryText)
                Text(ui: "This message is in Junk. Its links and pictures are turned off.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        } action: {
            Button(action: notJunk) {
                Text(ui: "Not junk").font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("reading.notJunk")
            .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.separator.opacity(0.5)))
    }
}

/// "Pictures are not downloaded" with Download pictures.
struct PicturesBar: View {
    let allow: () -> Void

    var body: some View {
        NoteLayout {
            HStack {
                Image(systemName: Icons.picturesBlocked)
                    .foregroundStyle(Theme.secondaryText)
                Text(ui: "Pictures are not downloaded.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        } action: {
            Button(action: allow) {
                Text(ui: "Download pictures").font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("reading.downloadPictures")
            .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.separator.opacity(0.5)))
    }
}
