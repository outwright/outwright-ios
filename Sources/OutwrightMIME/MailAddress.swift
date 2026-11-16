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
        guard let sign = email.lastIndex(of: "@") else {
            return email
        }
        let local = email[..<sign], domain = email[email.index(after: sign)...]
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
