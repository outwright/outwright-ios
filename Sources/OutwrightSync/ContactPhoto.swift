// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import ImageIO

/// A contact's inline photo is hostile: one claiming more pixels than a picture of a person needs
/// (a decompression bomb) is never decoded, here or by the iPhone's Contacts.
public enum ContactPhoto {
    /// Pixels on either side, at most.
    public static let maxSide = 8_000

    /// `data` when it reads as an image no larger than `maxSide` either way, else nil. Only the
    /// header is read.
    public static func safe(_ data: Data?) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let data, !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            (1...maxSide).contains(width), (1...maxSide).contains(height)
        else { return nil }
        return data
    }
}
