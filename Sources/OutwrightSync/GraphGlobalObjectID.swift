// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Graph's `iCalUId` is a meeting's GlobalObjectId in hex ([MS-OXOCAL] 2.2.1.27): a class id, the
/// occurrence's date (zero for the whole meeting), creation time, eight reserved bytes, then the
/// data's length and the data. The iCalendar UID it stands for ([MS-OXCICAL] 2.1.3.1.1.20.26) is
/// the one embedded after `vCal-Uid` when a meeting came from outside Exchange, else the hex of the
/// id with its date cleared.
enum GraphGlobalObjectID {
    private static let classID: [UInt8] = [
        0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00, 0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08
    ]
    private static let marker = Array("vCal-Uid".utf8) + [0x01, 0x00, 0x00, 0x00]
    /// The data's offset: class id 16, date 4, creation time 8, reserved 8, length 4.
    private static let header = 40
    private static let maxHex = 4_096

    /// The UID `iCalUId` stands for; `iCalUId` itself when it is no GlobalObjectId.
    static func uid(_ iCalUId: String) -> String {
        guard let bytes = bytes(iCalUId), bytes.count >= header, Array(bytes.prefix(16)) == classID else {
            return iCalUId
        }
        let size = (16..<20).reduce(0) { $0 | Int(bytes[$1 + 20]) << (8 * ($1 - 16)) }
        guard size <= bytes.count - header else { return iCalUId }
        let data = Array(bytes[header..<(header + size)])
        if data.count > marker.count, Array(data.prefix(marker.count)) == marker {
            let text = data.dropFirst(marker.count).prefix { $0 != 0 }
            if let embedded = String(bytes: text, encoding: .utf8), !embedded.isEmpty { return embedded }
        }
        var clean = bytes
        for index in 16..<20 { clean[index] = 0 }
        return clean.map { String(format: "%02X", $0) }.joined()
    }

    /// The bytes of an even-length hex string, nil for anything else (or past the cap).
    private static func bytes(_ hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2), digits.count <= maxHex else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index + 1 < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
