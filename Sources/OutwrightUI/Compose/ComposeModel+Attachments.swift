// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import ImageIO
public import OutwrightMIME
import UniformTypeIdentifiers

extension ComposeModel {
    /// Why a file was not attached.
    public enum AttachProblem: Sendable, Equatable {
        case tooLarge, unreadable
    }

    /// The files of one pick that were not attached, counted by why, for one alert.
    public struct AttachFailures: Sendable, Equatable {
        public var tooLarge = 0
        public var unreadable = 0
        /// Files past the most taken at once (`filesAtOnce`).
        public var pastTheLimit = 0

        public var isEmpty: Bool { tooLarge == 0 && unreadable == 0 && pastTheLimit == 0 }

        mutating func count(_ problem: AttachProblem?) {
            switch problem {
            case .tooLarge: tooLarge += 1
            case .unreadable: unreadable += 1
            case nil: break
            }
        }
    }

    /// The most files attached from one pick.
    static let filesAtOnce = 20

    /// Attaches the files picked (the first `filesAtOnce`), and counts those that weren't.
    func attachFiles(_ urls: [URL]) -> AttachFailures {
        var failed = AttachFailures(pastTheLimit: max(urls.count - Self.filesAtOnce, 0))
        for url in urls.prefix(Self.filesAtOnce) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            failed.count(attachFile(url, filename: url.lastPathComponent, mimeType: type))
        }
        return failed
    }

    /// Attaches the file at `url`, read only as far as the room left allows; nil when it was added.
    func attachFile(_ url: URL, filename: String, mimeType: String) -> AttachProblem? {
        switch AttachmentReader.read(url, limit: attachmentRoom) {
        case .read(let data):
            let added = attach(
                Attachment(filename: filename, mimeType: mimeType, contentID: nil, isInline: false, data: data))
            return added ? nil : .tooLarge
        case .tooLarge:
            return .tooLarge
        case .unreadable:
            return .unreadable
        }
    }

    /// Attaches a photo or video from the library, named for when it was added ("Photo 2026-11-16
    /// 12.30.05.jpg", a number after it when that is taken). HEIC, which not every reader shows, goes
    /// as JPEG, made away from the main actor.
    func attachPhoto(_ url: URL, type: UTType?, at date: Date) async -> AttachProblem? {
        let isVideo = type?.conforms(to: .movie) ?? false
        guard let type, type.conforms(to: .heic) || type.conforms(to: .heif) else {
            let given = type?.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            let suffix = type?.conforms(to: .jpeg) == true ? "jpg" : given
            let name = mediaName(isVideo ? "Video" : "Photo", suffix: suffix, at: date)
            return attachFile(url, filename: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
        }
        // The JPEG is about as large as the HEIC or larger: a HEIC past the room can't fit.
        let room = attachmentRoom
        let made = await Task.detached(priority: .userInitiated) { () -> Result<Data, AttachError> in
            switch AttachmentReader.read(url, limit: room) {
            case .read(let data): Self.jpeg(from: data).map { .success($0) } ?? .failure(.unreadable)
            case .tooLarge: .failure(.tooLarge)
            case .unreadable: .failure(.unreadable)
            }
        }.value
        switch made {
        case .success(let jpeg): return attachShot(jpeg, at: date)
        case .failure(let error): return error.problem
        }
    }

    /// Attaches a JPEG taken with the camera (or made of a HEIC), named for when it was added.
    func attachShot(_ jpeg: Data, at date: Date) -> AttachProblem? {
        let attachment = Attachment(
            filename: mediaName("Photo", suffix: "jpg", at: date), mimeType: "image/jpeg", contentID: nil,
            isInline: false, data: jpeg)
        return attach(attachment) ? nil : .tooLarge
    }

    /// "Photo 2026-11-16 12.30.05.jpg", or "… 2.jpg" and on when an attachment has that name.
    private func mediaName(_ word: String, suffix: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = L10n.string(word, locale: locale) + " " + formatter.string(from: date)
        let taken = Set(attachments.map { $0.filename.lowercased() })
        for number in 1...999 {
            let name = (number == 1 ? base : "\(base) \(number)") + "." + suffix
            if !taken.contains(name.lowercased()) { return name }
        }
        return "\(base) \(UUID().uuidString).\(suffix)"
    }

    /// Why a photo could not be made, carried out of the conversion.
    enum AttachError: Error {
        case tooLarge, unreadable

        var problem: AttachProblem { self == .tooLarge ? .tooLarge : .unreadable }
    }

    /// The most pixels on a converted photo's longer side, so memory stays bounded.
    nonisolated static let maxPixels = 4_096

    /// A picture as JPEG at quality 0.85, turned upright and at most `maxPixels` on its longer side.
    nonisolated static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { return nil }
        let size = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, size) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Room left for attachments, in bytes.
    var attachmentRoom: Int {
        max(attachmentLimit - attachmentBytes, 0)
    }

    /// Adds a file, unless the message would grow past 25 MB of attachments.
    @discardableResult
    public func attach(_ attachment: Attachment) -> Bool {
        guard attachmentBytes + attachment.data.count <= attachmentLimit else { return false }
        attachments.append(attachment)
        return true
    }

    /// The attachments' bytes, the quote's inline pictures among them.
    var attachmentBytes: Int {
        (attachments + (quoted?.inline ?? [])).reduce(0) { $0 + $1.data.count }
    }
}
