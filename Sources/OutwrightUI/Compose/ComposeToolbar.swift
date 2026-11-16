// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The glass capsule over the keyboard: attach a file, a photo, formatting, more. Formatting
/// swaps the row for bold, italic, underline, a bulleted line and a link.
struct ComposeToolbar: View {
    let model: ComposeModel
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection
    @Binding var showsCopies: Bool
    @State private var isFormatting = false
    @State private var isImporting = false
    @State private var photo: PhotosPickerItem?
    @State private var isAskingLink = false
    @State private var link = ""
    @State private var problem: ComposeModel.AttachProblem?

    var body: some View {
        HStack(spacing: 0) {
            if isFormatting {
                formatRow
            } else {
                mainRow
            }
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(20) { attachFile(url) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await attachPhoto(item) }
        }
        .alert(Text(ui: "Add a link"), isPresented: $isAskingLink) {
            TextField(text: $link) { Text(verbatim: "https://") }
                .emailEntry()
            Button { applyLink() } label: { Text(ui: "Add") }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        }
        // The reason is read from the presented value, so it holds while the alert closes.
        .alert(
            Text(ui: "The file was not added"), isPresented: Binding(presenting: $problem), presenting: problem
        ) { _ in
            Button { problem = nil } label: { Text(ui: "OK") }
        } message: { problem in
            switch problem {
            case .tooLarge: Text(ui: "Attachments can be at most 25 MB together.")
            case .unreadable: Text(ui: "The file could not be read.")
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            if let state = model.protection {
                // Encrypting signs too, so Sign is ticked and fixed while Encrypt is on.
                Menu {
                    Toggle(isOn: Binding(get: { state.lockOn }, set: { _ in model.toggleLock() })) {
                        Text(ui: "Encrypt")
                    }
                    Toggle(isOn: Binding(get: { state.lockOn || state.signOn }, set: { _ in model.toggleSign() })) {
                        Text(ui: "Sign")
                    }
                    .disabled(state.lockOn || !state.canProtect)
                } label: {
                    Image(systemName: state.lockOn ? "lock.fill" : state.signOn ? "signature" : "lock.open")
                        .frame(width: 52, height: 44)
                }
                .accessibilityLabel(Text(ui: "Encrypt or sign"))
                .accessibilityIdentifier("compose.lock")
            }
            button("Attach file", "paperclip") { isImporting = true }
            PhotosPicker(selection: $photo, matching: .images) {
                Image(systemName: "photo")
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel(Text(ui: "Add a photo"))
            button("Format", "textformat") { withAnimation(.snappy) { isFormatting = true } }
            Menu {
                Button {
                    withAnimation(.snappy) { showsCopies.toggle() }
                } label: {
                    ModuleLabel("Cc and Bcc", systemImage: "person.2")
                }
            } label: {
                Image(systemName: Icons.more)
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel(Text(ui: "More"))
        }
    }

    private var formatRow: some View {
        HStack(spacing: 0) {
            button("Back", "chevron.left") { withAnimation(.snappy) { isFormatting = false } }
            button("Bold", "bold") { toggle(.stronglyEmphasized) }
            button("Italic", "italic") { toggle(.emphasized) }
            button("Underline", "underline") { toggleUnderline() }
            button("Bulleted list", "list.bullet") { text.replaceSelection(&selection, withCharacters: "• ") }
            button("Link", "link") {
                link = ""
                isAskingLink = true
            }
        }
    }

    private func button(_ label: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ui: label))
    }

    // MARK: - Formatting

    private func toggle(_ intent: InlinePresentationIntent) {
        let current = selection.typingAttributes(in: text).inlinePresentationIntent ?? []
        let adding = !current.contains(intent)
        text.transformAttributes(in: &selection) { container in
            var value = container.inlinePresentationIntent ?? []
            if adding { value.insert(intent) } else { value.remove(intent) }
            container.inlinePresentationIntent = value.isEmpty ? nil : value
            container.font = Self.font(for: value)
        }
    }

    private func toggleUnderline() {
        let adding = selection.typingAttributes(in: text).underlineStyle == nil
        text.transformAttributes(in: &selection) { container in
            container.underlineStyle = adding ? .single : nil
        }
    }

    private func applyLink() {
        let typed = link.trimmingCharacters(in: .whitespaces)
        let withScheme = typed.contains("://") || typed.hasPrefix("mailto:") ? typed : "https://" + typed
        guard let url = URL(string: withScheme), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        text.transformAttributes(in: &selection) { container in
            container.link = url
        }
    }

    static func font(for intent: InlinePresentationIntent) -> Font? {
        switch (intent.contains(.stronglyEmphasized), intent.contains(.emphasized)) {
        case (true, true): .body.bold().italic()
        case (true, false): .body.bold()
        case (false, true): .body.italic()
        case (false, false): nil
        }
    }

    // MARK: - Attaching

    private func attachFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        attach(url, filename: url.lastPathComponent, mimeType: type)
    }

    private func attachPhoto(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        // A file, not its bytes: the size is checked before anything is read into memory.
        let picked: PickedPhoto?
        do {
            picked = try await item.loadTransferable(type: PickedPhoto.self)
        } catch {
            problem = .unreadable
            return
        }
        guard let picked else { return }
        defer { try? FileManager.default.removeItem(at: picked.url) }
        let type = item.supportedContentTypes.first
        let name = String(localized: "Photo", bundle: .module) + "." + (type?.preferredFilenameExtension ?? "jpg")
        attach(picked.url, filename: name, mimeType: type?.preferredMIMEType ?? "image/jpeg")
    }

    private func attach(_ url: URL, filename: String, mimeType: String) {
        problem = model.attachFile(url, filename: filename, mimeType: mimeType)
    }
}

/// A photo from the picker as a file of its own in the temporary folder, which the reader then
/// reads only as far as the room for attachments allows.
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedPhoto(url: copy)
        }
    }
}
