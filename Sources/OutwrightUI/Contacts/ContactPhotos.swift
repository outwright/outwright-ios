// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import OutwrightModel
import OutwrightSync

/// A contact's picture cut down once to the size it is drawn at, and kept by contact.
@MainActor
enum ContactPhotos {
    private final class Box {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    private static let cache = NSCache<NSString, Box>()

    /// The picture at `pixels` on its longer side, or nil when there is none or it can't be read.
    static func image(for contact: Contact, pixels: Int) -> CGImage? {
        guard let data = contact.photo, !data.isEmpty else { return nil }
        var hasher = Hasher()
        hasher.combine(data)
        let key = "\(contact.id.raw)-\(data.count)-\(hasher.finalize())-\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let image = thumbnail(data, pixels: pixels)
        cache.setObject(Box(image), forKey: key)
        return image
    }

    /// Nil too for a picture with a side past `ContactPhoto.maxSide`: it is never decoded.
    static func thumbnail(_ data: Data, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let data = ContactPhoto.safe(data),
            let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
        else { return nil }
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(pixels, 1_024))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary)
    }
}

extension ContactPhotos {
    /// The longer side of a picture given to a contact, at most.
    nonisolated static let writtenSide = 512

    /// A picked picture as a contact keeps it: at most `writtenSide` pixels on its longer side, as
    /// a JPEG; nil when it can't be read.
    nonisolated static func prepared(_ data: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: writtenSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
