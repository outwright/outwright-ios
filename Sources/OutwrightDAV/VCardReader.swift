// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Reads vCard 3.0 and 4.0 (RFC 2426, 6350). The input is hostile: sizes are capped, nothing
/// is indexed unchecked, and nothing in a card is ever fetched.
public enum VCardReader {
    /// An unfolded PHOTO line may be as long as a photo at the cap, base64 encoded.
    private static let photoLineBytes = DAVLimits.photoBytes / 3 * 4 + 4096

    public static func cards(_ data: Data) throws(VCardError) -> [VCard] {
        guard data.count <= DAVLimits.vCardBytes else { throw .tooLarge }
        var assembler = Assembler()
        for line in try unfold(Array(data)) {
            guard let parsed = ContentLine.parse(line) else { continue }
            try assembler.accept(property(parsed))
        }
        return try assembler.finish()
    }

    /// Collects properties between BEGIN:VCARD and END:VCARD.
    private struct Assembler {
        var cards: [VCard] = []
        var current: [VCardProperty]?
        var version = "3.0"

        mutating func accept(_ property: VCardProperty) throws(VCardError) {
            switch (property.name, property.value.uppercased()) {
            case ("BEGIN", "VCARD"):
                guard current == nil else { throw .malformed }
                current = []
                version = "3.0"
            case ("END", "VCARD"):
                guard let properties = current else { throw .malformed }
                guard cards.count < DAVLimits.cardsPerResource else { throw .tooLarge }
                cards.append(VCard(version: version, properties: properties))
                current = nil
            case ("BEGIN", _), ("END", _):
                break
            default:
                try append(property)
            }
        }

        private mutating func append(_ property: VCardProperty) throws(VCardError) {
            guard let properties = current else { return }
            if property.name == "VERSION" {
                version = property.value.hasPrefix("4") ? "4.0" : "3.0"
                return
            }
            guard properties.count < DAVLimits.vCardProperties else { throw .tooLarge }
            current?.append(property)
        }

        func finish() throws(VCardError) -> [VCard] {
            guard current == nil, !cards.isEmpty else { throw .malformed }
            return cards
        }
    }

    // MARK: - Lines

    private static func unfold(_ bytes: [UInt8]) throws(VCardError) -> [[UInt8]] {
        do {
            return try ContentLine.unfold(bytes, limit: DAVLimits.vCardLineBytes) { line in
                guard isImage(line) else { return .refuse }
                return line.count > photoLineBytes ? .drop : .keep
            }
        } catch { throw .tooLarge }
    }

    private static func isImage(_ line: [UInt8]) -> Bool {
        guard let property = ContentLine.parse(Array(line.prefix(128)) + [ContentLine.colon]) else { return false }
        return property.name == "PHOTO" || property.name == "LOGO"
    }

    private static let equals = ContentLine.equals

    private static func property(_ line: ParsedLine) -> VCardProperty {
        let value = decodeValue(name: line.name, parameters: line.parameters, raw: line.value)
        return VCardProperty(
            group: line.group, name: line.name, parameters: decodedParameters(line.parameters), value: value)
    }

    /// The value is stored decoded, so the parameters that described its encoding are dropped.
    private static func decodedParameters(_ parameters: [ContentParameter]) -> [ContentParameter] {
        parameters.compactMap { parameter in
            if parameter.name == "CHARSET" { return nil }
            guard parameter.name == "ENCODING" else { return parameter }
            let kept = parameter.values.filter { $0.uppercased() != "QUOTED-PRINTABLE" }
            return kept.isEmpty ? nil : ContentParameter(name: parameter.name, values: kept)
        }
    }

    private static func decodeValue(name: String, parameters: [ContentParameter], raw: [UInt8]) -> String {
        func parameter(_ key: String) -> [String] {
            parameters.filter { $0.name == key }.flatMap(\.values).map { $0.uppercased() }
        }
        let quotedPrintable = parameter("ENCODING").contains("QUOTED-PRINTABLE")
        let binary = parameter("ENCODING").contains { $0 == "B" || $0 == "BASE64" }
        let utf8Only = parameter("CHARSET").allSatisfy { $0 == "UTF-8" || $0 == "UTF8" }
        let bytes = quotedPrintable ? decodeQuotedPrintable(raw) : raw.filter { $0 != 0 }
        let decoded = utf8Only ? ContentLine.decode(bytes) : ContentLine.latin1(bytes)
        return binary || VCardText.keepsFileForm(name) ? decoded : ContentLine.unescape(decoded)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func decodeQuotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == equals {
                if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                    let low = hexValue(bytes[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
                index += 1
                continue
            }
            if byte != 0 { out.append(byte) }
            index += 1
        }
        return out
    }
}
