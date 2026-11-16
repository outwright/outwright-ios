// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A message in the results: an envelope on the accent colour.
struct MailIcon: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: "envelope.fill")
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
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: 72)
    }
}

/// A document drawn from SF Symbols, with the file's kind on it.
struct FileIcon: View {
    let name: String

    var body: some View {
        let ext = (name.split(separator: ".").last.map(String.init) ?? "").uppercased()
        Image(systemName: "doc")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.secondary)
            .overlay(alignment: .center) {
                Text(verbatim: ext.count <= 4 ? ext : "")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.delete)
                    .offset(y: 3)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Search covers the whole screen on the phone (a sheet where there is no such thing).
    func searchCover<Content: View>(
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
