// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A message's HTML with its colours turned for dark mode: each colour it sets keeps its hue and
/// gets the opposite lightness (in OKLab), so dark text on a light background reads light on dark.
/// Only colours change, and only where colours are written (a `style` attribute, the declarations
/// of a `<style>` element, the `color`, `bgcolor`, `text`, `link`, `vlink` and `alink` attributes);
/// text, selectors, addresses and pictures stay as they are. One linear pass over the bytes.
enum DarkColors {
    static func adapt(_ html: String) -> String {
        var scanner = Scanner(Array(html.utf8))
        scanner.run()
        return String(bytes: scanner.out, encoding: .utf8) ?? html
    }

    /// The colour turned around, in the form it was written in when it is hex or `rgb`, as hex
    /// otherwise; nil when it is no colour we know.
    static func inverted(_ token: String) -> String? {
        guard let color = RGBA(token) else { return nil }
        return color.invertingLightness().css(like: token)
    }

    private static let colorAttributes: Set<String> = ["color", "bgcolor", "text", "link", "vlink", "alink"]

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var out: [UInt8] = []

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            out.reserveCapacity(bytes.count)
        }

        func at(_ position: Int) -> UInt8? {
            bytes.indices.contains(position) ? bytes[position] : nil
        }

        func startsWith(_ text: String, at position: Int) -> Bool {
            for (offset, byte) in text.utf8.enumerated() {
                guard let found = at(position + offset), lower(found) == byte else { return false }
            }
            return true
        }

        mutating func copy(upTo end: Int) {
            let end = min(end, bytes.count)
            if index < end {
                out.append(contentsOf: bytes[index..<end])
                index = end
            }
        }

        /// The first position at or after `from` where `text` (lowercase) starts, or the end.
        func find(_ text: String, from: Int) -> Int {
            var position = from
            while position < bytes.count {
                if startsWith(text, at: position) { return position }
                position += 1
            }
            return bytes.count
        }

        mutating func run() {
            while index < bytes.count {
                guard let next = bytes[index...].firstIndex(of: UInt8(ascii: "<")) else {
                    copy(upTo: bytes.count)
                    return
                }
                copy(upTo: next)
                if startsWith("<!--", at: index) {
                    let close = find("-->", from: index + 4)
                    copy(upTo: close + 3)
                } else if let letter = at(index + 1), isLetter(letter) {
                    tag()
                } else {
                    copy(upTo: index + 1)
                }
            }
        }

        /// An opening tag (or a closing one, copied as it is): its colour attributes and style turned,
        /// and a `<style>` element's sheet after it.
        mutating func tag() {
            copy(upTo: index + 1)
            var nameEnd = index
            while let byte = at(nameEnd), isNameByte(byte) { nameEnd += 1 }
            let name = (String(bytes: bytes[index..<nameEnd].map(lower), encoding: .utf8) ?? "")
            copy(upTo: nameEnd)
            attributes()
            if name == "style" {
                let close = find("</style", from: index)
                let sheet = Array(bytes[min(index, close)..<close])
                out.append(contentsOf: DarkColors.sheet(sheet))
                index = close
            }
        }

        mutating func attributes() {
            while let byte = at(index) {
                if byte == UInt8(ascii: ">") {
                    copy(upTo: index + 1)
                    return
                }
                guard isNameByte(byte) else {
                    copy(upTo: index + 1)
                    continue
                }
                var nameEnd = index
                while let next = at(nameEnd), isNameByte(next) { nameEnd += 1 }
                let name = (String(bytes: bytes[index..<nameEnd].map(lower), encoding: .utf8) ?? "")
                copy(upTo: nameEnd)
                while let next = at(index), isSpace(next) { copy(upTo: index + 1) }
                guard at(index) == UInt8(ascii: "=") else { continue }
                copy(upTo: index + 1)
                while let next = at(index), isSpace(next) { copy(upTo: index + 1) }
                let value: [UInt8]
                if let quote = at(index), quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    copy(upTo: index + 1)
                    let end = bytes[index...].firstIndex(of: quote) ?? bytes.count
                    value = Array(bytes[index..<end])
                    index = end
                    out.append(contentsOf: turn(value, attribute: name))
                    copy(upTo: index + 1)
                } else {
                    var end = index
                    while let next = at(end), !isSpace(next), next != UInt8(ascii: ">") { end += 1 }
                    value = Array(bytes[index..<end])
                    index = end
                    out.append(contentsOf: turn(value, attribute: name))
                }
            }
        }

        func turn(_ value: [UInt8], attribute: String) -> [UInt8] {
            if attribute == "style" { return DarkColors.declarations(value) }
            if DarkColors.colorAttributes.contains(attribute) {
                let text = (String(bytes: value, encoding: .utf8) ?? "")
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                // An attribute colour may be written without its #.
                if let turned = inverted(trimmed) ?? inverted("#" + trimmed) { return Array(turned.utf8) }
            }
            return value
        }
    }

    /// A style sheet: the declarations in each rule turned, selectors and at-rules as they are.
    static func sheet(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var depth = 0
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "/"), bytes.indices.contains(index + 1), bytes[index + 1] == UInt8(ascii: "*") {
                index = commentEnd(bytes, from: index)
                continue
            }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                index = (bytes[(index + 1)...].firstIndex(of: byte) ?? bytes.count - 1) + 1
                continue
            }
            switch byte {
            case UInt8(ascii: "{"):
                // What came before was a selector or an at-rule.
                out.append(contentsOf: bytes[start...index])
                depth += 1
                start = index + 1
            case UInt8(ascii: ";") where depth > 0, UInt8(ascii: "}"):
                let part = Array(bytes[start..<index])
                out.append(contentsOf: depth > 0 ? declaration(part) : part)
                out.append(byte)
                if byte == UInt8(ascii: "}") { depth = max(0, depth - 1) }
                start = index + 1
            default:
                break
            }
            index += 1
        }
        let rest = Array(bytes[min(start, bytes.count)...])
        out.append(contentsOf: depth > 0 ? declaration(rest) : rest)
        return out
    }

    /// A list of declarations (a `style` attribute).
    static func declarations(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                index = (bytes[(index + 1)...].firstIndex(of: byte) ?? bytes.count - 1) + 1
                continue
            }
            if byte == UInt8(ascii: ";") {
                out.append(contentsOf: declaration(Array(bytes[start..<index])))
                out.append(byte)
                start = index + 1
            }
            index += 1
        }
        out.append(contentsOf: declaration(Array(bytes[min(start, bytes.count)...])))
        return out
    }

    private static func commentEnd(_ bytes: [UInt8], from: Int) -> Int {
        var index = from + 2
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") { return index + 2 }
            index += 1
        }
        return bytes.count
    }

    /// One `property: value`: the colours in its value turned when the property is one that colours.
    static func declaration(_ bytes: [UInt8]) -> [UInt8] {
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return bytes }
        let property = (String(bytes: bytes[..<colon].map(lower), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let colours = property == "color" || property == "background" || property.hasSuffix("-color")
            || property.hasPrefix("border") || property.hasPrefix("outline") || property.hasSuffix("-shadow")
        guard colours else { return bytes }
        return Array(bytes[...colon]) + value(Array(bytes[(colon + 1)...]))
    }

    /// A value's colour tokens turned; `url(…)`, strings and everything else as they are.
    static func value(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                let end = min((bytes[(index + 1)...].firstIndex(of: byte) ?? bytes.count - 1) + 1, bytes.count)
                out.append(contentsOf: bytes[index..<end])
                index = end
                continue
            }
            guard byte == UInt8(ascii: "#") || isLetter(byte) else {
                out.append(byte)
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, isNameByte(bytes[end]) { end += 1 }
            var token = (String(bytes: bytes[index..<end], encoding: .utf8) ?? "")
            let word = token.lowercased()
            if word == "rgb" || word == "rgba" || word == "url", end < bytes.count, bytes[end] == UInt8(ascii: "(") {
                let close = bytes[end...].firstIndex(of: UInt8(ascii: ")")) ?? bytes.count - 1
                end = close + 1
                token = (String(bytes: bytes[index..<end], encoding: .utf8) ?? "")
                if word == "url" {
                    out.append(contentsOf: bytes[index..<end])
                    index = end
                    continue
                }
            }
            out.append(contentsOf: Array((inverted(token) ?? token).utf8))
            index = end
        }
        return out
    }
}

private func lower(_ byte: UInt8) -> UInt8 {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
}

private func isLetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lower(byte))
}

private func isNameByte(_ byte: UInt8) -> Bool {
    isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
        || byte == UInt8(ascii: "_")
}

private func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
}

/// A colour as CSS writes it: hex, `rgb()`/`rgba()`, or one of the common names.
struct RGBA: Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    static let names: [String: UInt32] = [
        "black": 0x000000, "white": 0xffffff, "red": 0xff0000, "green": 0x008000, "blue": 0x0000ff,
        "yellow": 0xffff00, "gray": 0x808080, "grey": 0x808080, "silver": 0xc0c0c0, "maroon": 0x800000,
        "navy": 0x000080, "purple": 0x800080, "teal": 0x008080, "olive": 0x808000, "lime": 0x00ff00,
        "aqua": 0x00ffff, "cyan": 0x00ffff, "fuchsia": 0xff00ff, "magenta": 0xff00ff, "orange": 0xffa500,
        "darkgray": 0xa9a9a9, "darkgrey": 0xa9a9a9, "lightgray": 0xd3d3d3, "lightgrey": 0xd3d3d3,
        "dimgray": 0x696969, "dimgrey": 0x696969, "whitesmoke": 0xf5f5f5, "gainsboro": 0xdcdcdc,
        "darkblue": 0x00008b, "darkred": 0x8b0000, "darkgreen": 0x006400
    ]

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(_ token: String) {
        let text = token.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
            let short = digits.count <= 4
            let parts: [Double] = stride(from: 0, to: digits.count, by: short ? 1 : 2).map { start in
                let pair = short ? String([digits[start], digits[start]]) : String(digits[start..<(start + 2)])
                return Double(Int(pair, radix: 16) ?? 0) / 255
            }
            guard parts.count >= 3 else { return nil }
            self.init(red: parts[0], green: parts[1], blue: parts[2], alpha: parts.count > 3 ? parts[3] : 1)
        } else if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
            open < close {
            let inside = text[text.index(after: open)..<close]
            let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ part: String, scale: Double) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / scale }
            }
            guard let red = channel(parts[0], scale: 255), let green = channel(parts[1], scale: 255),
                let blue = channel(parts[2], scale: 255) else { return nil }
            let alpha = parts.count == 4 ? channel(parts[3], scale: 1) : 1
            guard let alpha else { return nil }
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        } else if let value = Self.names[text] {
            self.init(
                red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                blue: Double(value & 0xff) / 255)
        } else {
            return nil
        }
        guard [red, green, blue, alpha].allSatisfy(\.isFinite) else { return nil }
        red = min(max(red, 0), 1)
        green = min(max(green, 0), 1)
        blue = min(max(blue, 0), 1)
        alpha = min(max(alpha, 0), 1)
    }

    /// The same hue and chroma at the opposite lightness (OKLab), fitted back into sRGB.
    func invertingLightness() -> RGBA {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func gamma(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        let (linearRed, linearGreen, linearBlue) = (linear(red), linear(green), linear(blue))
        let long = cbrt(0.4122214708 * linearRed + 0.5363325363 * linearGreen + 0.0514459929 * linearBlue)
        let medium = cbrt(0.2119034982 * linearRed + 0.6806995451 * linearGreen + 0.1073969566 * linearBlue)
        let short = cbrt(0.0883024619 * linearRed + 0.2817188376 * linearGreen + 0.6299787005 * linearBlue)
        let lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
        let greenRed = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
        let blueYellow = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        let turned = 1 - lightness
        let long2 = pow(turned + 0.3963377774 * greenRed + 0.2158037573 * blueYellow, 3)
        let medium2 = pow(turned - 0.1055613458 * greenRed - 0.0638541728 * blueYellow, 3)
        let short2 = pow(turned - 0.0894841775 * greenRed - 1.2914855480 * blueYellow, 3)
        return RGBA(
            red: gamma(4.0767416621 * long2 - 3.3077115913 * medium2 + 0.2309699292 * short2),
            green: gamma(-1.2684380046 * long2 + 2.6097574011 * medium2 - 0.3413193965 * short2),
            blue: gamma(-0.0041960863 * long2 - 0.7034186147 * medium2 + 1.7076147010 * short2),
            alpha: alpha)
    }

    /// As CSS: `rgba()` when the original was `rgb`-written or not opaque, hex otherwise.
    func css(like original: String) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        if original.lowercased().hasPrefix("rgb") || alpha < 1 {
            return "rgba(\(byte(red)), \(byte(green)), \(byte(blue)), \(alpha))"
        }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
