// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The glass capsule over the keyboard: attach (a file, photos, the camera), formatting, and More
/// (encrypt and sign). Formatting swaps the row for bold, italic, underline, lists and a link.
struct ComposeToolbar: View {
    let model: ComposeModel
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection
    /// Opens where the account is set up to encrypt; nil when the build has nothing to set up.
    var setUp: (() -> Void)?
    @ScaledMetric(relativeTo: .title3) private var tapWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .title3) private var tapHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .title3) private var barHeight: CGFloat = 52
    @State private var isFormatting = false
    @State private var isImporting = false
    @State private var isPickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var isShooting = false
    @State private var isAskingLink = false
    @State private var linkText = ""
    @State private var link = ""
    @State private var linkRejected = false
    @State private var failures: ComposeModel.AttachFailures?

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
        .frame(height: barHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        // What of a forwarded or answered message didn't fit is said as compose opens.
        .onAppear { show(model.takeLeftOut()) }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            show(model.attachFiles(urls))
        }
        .photosPicker(
            isPresented: $isPickingPhotos, selection: $photos, maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { await attachPhotos(items) }
        }
        .screenCover(isPresented: $isShooting) {
            CameraPicker { jpeg in show(failed(model.attachShot(jpeg, at: Date()))) }
                .ignoresSafeArea()
        }
        .alert(Text(ui: "Add a link"), isPresented: $isAskingLink) {
            if !hasSelection {
                TextField(text: $linkText) { Text(ui: "Text to show") }
            }
            TextField(text: $link) { Text(verbatim: "https://") }
                .urlEntry()
            Button { applyLink() } label: { Text(ui: "Add") }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        }
        .alert(Text(ui: "That isn't a web or email address"), isPresented: $linkRejected) {
            Button { linkRejected = false } label: { Text(ui: "OK") }
        } message: {
            Text(ui: "Type an address like example.org or name@example.org.")
        }
        // The counts are read from the presented value, so they hold while the alert closes.
        .alert(
            Text(ui: "Not everything was added"), isPresented: Binding(presenting: $failures), presenting: failures
        ) { _ in
            Button { failures = nil } label: { Text(ui: "OK") }
        } message: { failed in
            Text(verbatim: Self.explanation(failed))
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            Menu {
                Button { isImporting = true } label: { ModuleLabel("Files", systemImage: Icons.document) }
                Button { isPickingPhotos = true } label: { ModuleLabel("Photos", systemImage: Icons.picture) }
                if CameraPicker.isAvailable {
                    Button { isShooting = true } label: { ModuleLabel("Camera", systemImage: Icons.camera) }
                }
            } label: {
                Image(systemName: Icons.attachment)
                    .frame(width: tapWidth, height: tapHeight)
            }
            .accessibilityLabel(Text(ui: "Attach file"))
            button("Format", Icons.format) { withAnimation(.snappy) { isFormatting = true } }
            if let state = model.protection {
                more(state)
            }
        }
    }

    /// Encrypt and Sign (encrypting signs too, so Sign is ticked and fixed while Encrypt is on, unless
    /// the protection lets the owner sign separately); an account that can't protect offers to be set up
    /// instead.
    private func more(_ state: ComposeProtection) -> some View {
        Menu {
            if !state.canProtect, let setUp {
                Button(action: setUp) {
                    ModuleLabel("Set up encryption…", systemImage: Icons.locked)
                }
            } else {
                Toggle(isOn: Binding(get: { state.lockOn }, set: { _ in model.toggleLock() })) {
                    Label { Text(ui: "Encrypt") } icon: { Image(systemName: Icons.locked) }
                }
                .disabled(!state.canProtect || !state.canEncrypt)
                let signFixed = state.lockOn && !state.signsSeparately
                Toggle(isOn: Binding(get: { signFixed || state.signOn }, set: { _ in model.toggleSign() })) {
                    Label { Text(ui: "Sign") } icon: { Image(systemName: Icons.signed) }
                }
                .disabled(signFixed || !state.canProtect)
            }
        } label: {
            Image(systemName: Icons.more)
                .frame(width: tapWidth, height: tapHeight)
        }
        .accessibilityLabel(Text(ui: "More"))
        .accessibilityIdentifier("compose.lock")
    }

    private var formatRow: some View {
        HStack(spacing: 0) {
            // Seven buttons: a little narrower than the main row's, so the row fits a phone.
            let width = tapWidth * 0.84
            button("Back", Icons.back, width: width) { withAnimation(.snappy) { isFormatting = false } }
            button("Bold", Icons.bold, width: width) { toggle(.stronglyEmphasized) }
            button("Italic", Icons.italic, width: width) { toggle(.emphasized) }
            button("Underline", Icons.underline, width: width) { toggleUnderline() }
            button("Bulleted list", Icons.bulletList, width: width) { toggleList(.bullet) }
            button("Numbered list", Icons.numberedList, width: width) { toggleList(.numbered) }
            button("Link", Icons.link, width: width) {
                linkText = ""
                link = ""
                isAskingLink = true
            }
        }
    }

    private func button(
        _ label: LocalizedStringKey, _ symbol: String, width: CGFloat? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: width ?? tapWidth, height: tapHeight)
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

    /// Starts or ends a bulleted or numbered list on the cursor's line.
    private func toggleList(_ kind: ListEditing.Kind) {
        let point: AttributedString.Index
        switch selection.indices(in: text) {
        case .insertionPoint(let index): point = index
        case .ranges(let ranges): point = ranges.ranges.first?.lowerBound ?? text.endIndex
        }
        let offset = text.characters.distance(from: text.startIndex, to: point)
        text.transform(updating: &selection) { body in
            ListEditing.toggle(kind, at: offset, in: &body)
        }
    }

    /// Text is selected: the link goes on it. Else the link's text is asked for too.
    private var hasSelection: Bool {
        guard case .ranges(let ranges) = selection.indices(in: text) else { return false }
        return ranges.ranges.contains { !$0.isEmpty }
    }

    private func applyLink() {
        guard let url = Self.linkURL(link) else {
            linkRejected = true
            return
        }
        if hasSelection {
            text.transformAttributes(in: &selection) { container in
                container.link = url
            }
        } else {
            let shown = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            var piece = AttributedString(shown.isEmpty ? link.trimmingCharacters(in: .whitespaces) : shown)
            piece.link = url
            text.replaceSelection(&selection, with: piece)
        }
    }

    /// A web or mail address as typed ("example.org" is taken as https); nil when it is neither.
    static func linkURL(_ typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.contains("://") || trimmed.lowercased().hasPrefix("mailto:")
        let withScheme = hasScheme ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return (url.host ?? "").contains(".") ? url : nil
        case "mailto":
            let address = RecipientParser.address(from: String(withScheme.dropFirst("mailto:".count)))
            return address == nil ? nil : url
        default: return nil
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

    /// Attaches the photos and videos picked, then says at once what wasn't added.
    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        var failed = ComposeModel.AttachFailures()
        for item in items {
            // A file, not its bytes: the size is checked before anything is read into memory.
            guard let picked = try? await item.loadTransferable(type: PickedPhoto.self) else {
                failed.count(.unreadable)
                continue
            }
            defer { try? FileManager.default.removeItem(at: picked.url) }
            let type = UTType(filenameExtension: picked.url.pathExtension) ?? item.supportedContentTypes.first
            failed.count(await model.attachPhoto(picked.url, type: type, at: Date()))
        }
        show(failed)
    }

    private func failed(_ problem: ComposeModel.AttachProblem?) -> ComposeModel.AttachFailures {
        var failed = ComposeModel.AttachFailures()
        failed.count(problem)
        return failed
    }

    private func show(_ failed: ComposeModel.AttachFailures) {
        if !failed.isEmpty { failures = failed }
    }

    /// One line for each reason files were not added.
    static func explanation(_ failed: ComposeModel.AttachFailures) -> String {
        var lines: [String] = []
        if failed.tooLarge > 0 {
            lines.append(String(localized: "\(failed.tooLarge) files were not added (too large)", bundle: .module))
        }
        if failed.unreadable > 0 {
            lines.append(String(localized: "\(failed.unreadable) files could not be read", bundle: .module))
        }
        if failed.pastTheLimit > 0 {
            let count = failed.pastTheLimit
            lines.append(
                String(localized: "\(count) files were left out: at most 20 are added at a time", bundle: .module))
        }
        return lines.joined(separator: "\n")
    }
}

/// A photo from the picker as a file of its own in the temporary folder, which the reader then
/// reads only as far as the room for attachments allows.
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, importing: copy)
        FileRepresentation(importedContentType: .movie, importing: copy)
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PickedPhoto {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(UUID().uuidString)")
            .appendingPathExtension(received.file.pathExtension)
        try FileManager.default.copyItem(at: received.file, to: copy)
        return PickedPhoto(url: copy)
    }
}
