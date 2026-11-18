// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// PHOTO: read only when inline, never fetched from an address; written inline.
extension VCard {
    /// The photo a PHOTO property holds inline (a base64 `data:` URI, or `ENCODING=b`), nil for one
    /// at an address or past the cap.
    static func inlinePhoto(_ property: VCardProperty) -> Data? {
        let value = property.value
        let payload: Substring
        if value.prefix(5).lowercased() == "data:" {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            guard value[..<comma].lowercased().contains(";base64") else { return nil }
            payload = value[value.index(after: comma)...]
        } else if property.parameters.contains(where: {
            $0.name == "ENCODING" && $0.values.contains { ["b", "base64"].contains($0.lowercased()) }
        }) {
            payload = value[...]
        } else {
            return nil
        }
        guard payload.utf8.count <= DAVLimits.photoBytes / 3 * 4 + 16 else { return nil }
        guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
            data.count <= DAVLimits.photoBytes
        else { return nil }
        return data
    }

    /// Writes `photo` inline in the card's own form (RFC 6350 `data:` URI in 4.0, `ENCODING=b` before
    /// it) over the inline photo read, else over any other PHOTO; nil removes the inline one.
    func updatePhoto(_ photo: Data?, _ props: inout [VCardProperty]) {
        let inline = props.firstIndex { $0.name == "PHOTO" && Self.inlinePhoto($0) != nil }
        guard let photo else {
            if let inline { props.remove(at: inline) }
            return
        }
        let type = photo.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpeg"
        let base64 = photo.base64EncodedString()
        var property = VCardProperty(name: "PHOTO", value: base64)
        if version.hasPrefix("4") {
            property.value = "data:image/\(type);base64," + base64
        } else {
            property.parameters = [
                VCardParameter(name: "ENCODING", values: ["b"]),
                VCardParameter(name: "TYPE", values: [type.uppercased()])
            ]
        }
        if let place = inline ?? props.firstIndex(where: { $0.name == "PHOTO" }) {
            property.group = props[place].group
            props[place] = property
        } else {
            props.append(property)
        }
    }
}
