// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import SwiftUI

/// A message's attachments; tapping one opens it (`opensAttachment`).
struct AttachmentList: View {
    let attachments: [Attachment]
    @State private var opening: ShownAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                Button {
                    opening = ShownAttachment(attachment: attachment)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AttachmentFiles.icon(attachment.mimeType))
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.filename.isEmpty ? String(localized: "Attachment", bundle: .module)
                                : attachment.filename)
                                .lineLimit(1)
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .opensAttachment($opening)
    }
}

/// Attachments are written to a private temporary folder for Quick Look: the one shown, until it is
/// closed or another is opened.
enum AttachmentFiles {
    /// How an attachment is opened.
    enum Presentation: Equatable {
        /// Quick Look: pictures, PDFs, documents.
        case quickLook
        /// HTML, in the locked web view like a message (Quick Look would render it in a web view of
        /// its own, outside the lock).
        case lockedWeb
        /// Markup that can carry script or fetches (SVG, XML): its text only, or shared.
        case text
    }

    /// What Quick Look may show, by the extension of the file it is handed: documents, pictures,
    /// plain text, audio and video. Anything else (HTML, SVG, XML, web archives, unknown kinds) is
    /// never handed to it, since it could render it in a web view of its own.
    static let quickLookExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
        "txt", "csv", "rtf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp",
        "mp3", "m4a", "aac", "wav", "aiff", "mp4", "m4v", "mov"
    ]

    /// By the name Quick Look would get (`safeName`) and by the declared type: HTML (by either) in the
    /// locked web view, Quick Look only for the safe kinds, and everything else as text or shared.
    static func presentation(_ attachment: Attachment) -> Presentation {
        let type = attachment.mimeType.lowercased()
        // The extension as the file system reads the written name (none for one ending in a dot).
        let name = safeName(attachment.filename).lowercased()
        let fileExtension = (name as NSString).pathExtension
        let hasExtension = !fileExtension.isEmpty
        if type == "text/html" || (hasExtension && ["html", "htm", "shtml"].contains(fileExtension)) {
            return .lockedWeb
        }
        let markupTypes = ["image/svg+xml", "application/xml", "text/xml", "application/xhtml+xml"]
        if markupTypes.contains(type) || type.hasSuffix("+xml") {
            return .text
        }
        return hasExtension && quickLookExtensions.contains(fileExtension) ? .quickLook : .text
    }

    /// Locked while the device is: file protection is the iPhone's. macOS refuses the option for
    /// a temporary file, so there (the package's tests) the file is written without it.
    private static var protection: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtection]
        #else
            [.atomic]
        #endif
    }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Writes the attachment for Quick Look; the one opened before goes, since only one is shown at
    /// a time.
    static func write(_ attachment: Attachment) -> URL? {
        removeAll()
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(safeName(attachment.filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: protection)
            return url
        } catch {
            return nil
        }
    }

    /// Every file left from before, such as one Quick Look showed when the app was closed. Called
    /// once at launch. (One Quick Look at a time: the iPhone app has one window; an iPad window
    /// of its own would need the files of other windows kept.)
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The file's own name without anything that would leave the folder.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/\\:\0".contains($0) ? "_" : $0 }
        let text = String(String(cleaned).prefix(120)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.hasPrefix(".") ? "attachment" + text : text
    }

    static func icon(_ mimeType: String) -> String {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") { return "doc.text" }
        if type.contains("zip") { return "doc.zipper" }
        if type.contains("calendar") { return "calendar" }
        return "doc"
    }
}

/// Removes the attachment files a previous run left behind; the app calls it once at launch.
public func removeLeftoverAttachmentFiles() {
    AttachmentFiles.removeAll()
}
