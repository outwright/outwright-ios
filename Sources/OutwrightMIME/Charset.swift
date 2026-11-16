// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Bytes in any IANA charset to text. Never fails.
public enum Charset {
    /// Decodes with the charset `label` names. An unknown label, or bytes that do not fit the
    /// charset, fall back to UTF-8 when the bytes are valid UTF-8 and to Latin-1 otherwise.
    public static func decode(_ bytes: Data, label: String?) -> String {
        if let encoding = encoding(for: label) {
            if let text = String(data: bytes, encoding: encoding) { return text }
            // swiftlint:disable:next optional_data_string_conversion
            if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    static func encoding(for label: String?) -> String.Encoding? {
        guard let label else { return nil }
        let clean = label.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
        guard !clean.isEmpty, clean.count <= 64 else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(clean as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
