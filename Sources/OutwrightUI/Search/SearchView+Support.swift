// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A message in the results: an envelope on the accent colour.
struct MailIcon: View {
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 44

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: Icons.mailFilled)
                    .foregroundStyle(Theme.onAccent)
            }
            .accessibilityHidden(true)
    }
}

/// A frequent person: the avatar, the first name and the rest under it.
struct PersonBadge: View {
    let person: Address

    var body: some View {
        let words = (person.name ?? "").split(separator: " ").map(String.init)
        VStack(spacing: 4) {
            Avatar(name: person.name, email: person.email, size: 64)
            Text(words.first ?? person.email.split(separator: "@").first.map(String.init) ?? person.email)
                .font(.body)
                .foregroundStyle(.primary)
            Text(words.dropFirst().joined(separator: " "))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .lineLimit(1)
        .frame(width: 72)
    }
}

/// A document drawn from SF Symbols, with the file's kind on it.
struct FileIcon: View {
    let name: String
    @ScaledMetric(relativeTo: .title) private var glyph: CGFloat = 34
    @ScaledMetric(relativeTo: .caption2) private var kind: CGFloat = 8
    @ScaledMetric(relativeTo: .title) private var box: CGFloat = 44

    var body: some View {
        let ext = (name.split(separator: ".").last.map(String.init) ?? "").uppercased()
        Image(systemName: Icons.document)
            .font(.system(size: glyph, weight: .light))
            .foregroundStyle(Theme.secondaryText)
            .overlay(alignment: .center) {
                Text(verbatim: ext.count <= 4 ? ext : "")
                    .font(.system(size: kind, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .offset(y: 3)
            }
            .frame(width: box, height: box)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Compose on a phone covers the whole screen (else a sheet).
    func screenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// Search and the first account's Add account cover the whole screen on the phone (else a sheet).
    func screenCover<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}

extension View {
    /// Text typed as it is: no capital first letter, no corrections.
    func plainEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
