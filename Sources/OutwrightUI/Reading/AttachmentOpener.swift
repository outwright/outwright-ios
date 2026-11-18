// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import SwiftUI
#if os(iOS)
import QuickLook
#endif

extension View {
    /// Opens the attachment set in `request` the way a message's are opened: Quick Look for the safe
    /// kinds, HTML in the locked web view, markup as its text (`AttachmentFiles.presentation`); the
    /// request is cleared once taken.
    func opensAttachment(_ request: Binding<ShownAttachment?>) -> some View {
        modifier(AttachmentOpener(request: request))
    }
}

private struct AttachmentOpener: ViewModifier {
    @Binding var request: ShownAttachment?
    @Environment(AppModel.self) private var app: AppModel?
    @State private var previewURL: URL?
    /// An HTML or markup attachment open in a sheet of its own (never Quick Look).
    @State private var shown: ShownAttachment?

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .quickLookPreview($previewURL)
            #endif
            .sheet(item: $shown, onDismiss: { app?.openPending() }, content: { AttachmentSheet(shown: $0) })
            .closesForEvents(isOpen: shown != nil) { shown = nil }
            .onChange(of: previewURL) { old, _ in
                if let old { AttachmentFiles.remove(old) }
            }
            // Not removed on disappearing: Quick Look may still show it. The next one opened replaces it.
            .onChange(of: request?.id) { _, id in
                guard id != nil, let taken = request else { return }
                request = nil
                switch AttachmentFiles.presentation(taken.attachment) {
                case .quickLook:
                    previewURL = AttachmentFiles.write(taken.attachment)
                case .lockedWeb, .text:
                    shown = taken
                }
            }
    }
}

/// An attachment shown by Outwright itself.
struct ShownAttachment: Identifiable {
    let id = UUID()
    let attachment: Attachment

    /// The attachment's bytes as text (UTF-8, anything else replaced), at most 2 MB of it.
    var text: String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: attachment.data.prefix(2 << 20), as: UTF8.self)
    }
}

/// HTML in the locked web view, as a message is shown; markup (SVG, XML) as its text. Either can
/// be shared.
private struct AttachmentSheet: View {
    let shown: ShownAttachment
    @State private var height: CGFloat = 400
    @State private var webUnavailable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text(verbatim: shown.attachment.filename))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
                ToolbarItem {
                    ShareLink(item: shown.text)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if AttachmentFiles.presentation(shown.attachment) == .lockedWeb, !webUnavailable {
            LockedWebView(
                html: shown.text, attachments: [], allowRemote: false, height: $height, onLink: { _ in },
                onUnavailable: { webUnavailable = true }
            )
            .frame(height: height)
        } else {
            plain
        }
        #else
        plain
        #endif
    }

    private var plain: some View {
        Text(verbatim: shown.text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding(16)
    }
}
