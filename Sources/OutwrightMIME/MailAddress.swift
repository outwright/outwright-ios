// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Addresses as they go on the wire: a non-ASCII domain as its A-labels (IDNA, RFC 5890, by
/// Punycode, RFC 3492), which every server takes; the local part as it is, which needs SMTPUTF8
/// (RFC 6531) when it is not ASCII.
public enum MailAddress {
    /// Longest DNS label (RFC 1035 section 2.3.4).
    static let maxLabel = 63

    /// The address with its domain in A-labels; nil when the domain has no ASCII form. Text
    /// without an `@` is given back as it is.
    public static func ascii(_ email: String) -> String? {
        let scalars = email.unicodeScalars
        guard let sign = domainAt(scalars) else {
            return email
        }
        let local = String(scalars[..<sign]), domain = String(scalars[scalars.index(after: sign)...])
        guard let ascii = asciiDomain(String(domain)) else {
            return nil
        }
        return local + "@" + ascii
    }

    /// Each non-ASCII label lowercased, composed (NFC) and written as `xn--` plus its Punycode;
    /// ASCII labels stay as they are. Nil when a label comes out longer than DNS takes.
    public static func asciiDomain(_ domain: String) -> String? {
        var labels: [String] = []
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.unicodeScalars.allSatisfy(\.isASCII) else {
                labels.append(String(label))
                continue
            }
            let scalars = Array(label.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars)
            guard let encoded = punycode(scalars.map(\.value)) else {
                return nil
            }
            let written = "xn--" + encoded
            guard written.utf8.count <= maxLabel else {
                return nil
            }
            labels.append(written)
        }
        return labels.joined(separator: ".")
    }

    /// An addr-spec (RFC 5322 section 3.4.1) as kept and sent: CR, LF and NUL gone everywhere;
    /// outside quoted strings also white space (the folding between tokens) and the characters of
    /// `alsoDrop`; inside them every other character kept, escapes as escapes. An unclosed quoted
    /// string is closed, and a local part quoted though it needs no quotes is unquoted, being the
    /// same mailbox.
    public static func addrSpec(_ text: String, alsoDrop: Set<Unicode.Scalar> = []) -> String {
        var out = String.UnicodeScalarView()
        var inQuote = false, escaped = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" || scalar == "\0" {
                continue
            } else if escaped {
                escaped = false
                out.append(scalar)
            } else if inQuote {
                out.append(scalar)
                if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inQuote = false
                }
            } else if !scalar.properties.isWhitespace && !alsoDrop.contains(scalar) {
                out.append(scalar)
                inQuote = scalar == "\""
            }
        }
        if escaped {
            out.removeLast()
        }
        if inQuote {
            out.append("\"")
        }
        return unquotedLocalPart(out)
    }

    /// The address with a local part of one quoted string written as a dot-atom when its text is one.
    private static func unquotedLocalPart(_ spec: String.UnicodeScalarView) -> String {
        guard let sign = domainAt(spec), spec.first == "\"", sign > spec.index(after: spec.startIndex),
              spec[spec.index(before: sign)] == "\""
        else {
            return String(spec)
        }
        var text = String.UnicodeScalarView()
        var escaped = false
        for scalar in spec[spec.index(after: spec.startIndex)..<spec.index(before: sign)] {
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
                continue
            } else if scalar == "\"" {
                return String(spec) // more than one quoted string
            }
            text.append(scalar)
        }
        guard isDotAtom(text) else {
            return String(spec)
        }
        return String(text) + String(spec[sign...])
    }

    /// Atext runs joined by single dots (RFC 5322 section 3.2.3, with RFC 6532's UTF-8).
    private static func isDotAtom(_ text: String.UnicodeScalarView) -> Bool {
        String(text).split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(isAtext)
        }
    }

    private static func isAtext(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return !scalar.properties.isWhitespace && scalar.properties.generalCategory != .control
        }
        return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
            || "!#$%&'*+-/=?^_`{|}~".unicodeScalars.contains(scalar)
    }

    /// The `@` before the domain: the last one outside quoted strings.
    private static func domainAt(_ scalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index? {
        var sign: String.UnicodeScalarView.Index?
        var inQuote = false, escaped = false
        for index in scalars.indices {
            let scalar = scalars[index]
            if escaped {
                escaped = false
            } else if scalar == "\\" && inQuote {
                escaped = true
            } else if scalar == "\"" {
                inQuote.toggle()
            } else if scalar == "@" && !inQuote {
                sign = index
            }
        }
        return sign
    }

    // MARK: - Punycode (RFC 3492 section 6.3)

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    /// At most `maxLabel` code points (nil for more), so every sum below stays far inside `Int`:
    /// the largest delta is about 0x10FFFF × 64.
    static func punycode(_ input: [UInt32]) -> String? {
        guard input.count <= maxLabel else {
            return nil
        }
        let points = input.map { Int($0) }
        var output = String(String.UnicodeScalarView(input.filter { $0 < 0x80 }.compactMap(Unicode.Scalar.init)))
        let basic = output.unicodeScalars.count
        var handled = basic
        if basic > 0 {
            output.append("-")
        }
        var codePoint = initialN, delta = 0, bias = initialBias
        while handled < points.count {
            guard let next = points.filter({ $0 >= codePoint }).min() else {
                return nil
            }
            delta += (next - codePoint) * (handled + 1)
            codePoint = next
            for point in points {
                if point < codePoint {
                    delta += 1
                }
                guard point == codePoint else {
                    continue
                }
                var rest = delta
                // Each round divides the rest by at least 10, so a handful of rounds end it.
                for position in stride(from: base, through: base * 16, by: base) {
                    let threshold = position <= bias ? tMin : (position >= bias + tMax ? tMax : position - bias)
                    if rest < threshold {
                        break
                    }
                    output.append(digit(threshold + (rest - threshold) % (base - threshold)))
                    rest = (rest - threshold) / (base - threshold)
                }
                output.append(digit(rest))
                bias = adapt(delta, points: handled + 1, first: handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            codePoint += 1
        }
        return output
    }

    private static func adapt(_ delta: Int, points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var offset = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            offset += base
        }
        return offset + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ value: Int) -> Character {
        let scalar = value < 26 ? 0x61 + value : 0x30 + value - 26
        return Character(Unicode.Scalar(UInt8(clamping: scalar)))
    }
}
