// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Base64 and quoted-printable, read leniently.
enum TransferEncoding {
    static func decode(_ bytes: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": base64(bytes)
        case "quoted-printable": quotedPrintable(bytes, header: false)
        default: bytes
        }
    }

    static func sextet(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: byte - 0x41
        case 0x61...0x7A: byte - 0x61 + 26
        case 0x30...0x39: byte - 0x30 + 52
        case 0x2B, 0x2D: 62
        case 0x2F, 0x5F: 63
        default: nil
        }
    }

    static func base64(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count / 4 * 3 + 3)
        var acc: UInt32 = 0
        var bits: UInt32 = 0
        for byte in input {
            guard let value = sextet(byte) else { continue }
            acc = ((acc << 6) | UInt32(value)) & 0xFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xFF))
                acc &= (1 << bits) - 1
            }
        }
        return out
    }

    private static func hex(_ byte: UInt8?) -> UInt8? {
        guard let byte else { return nil }
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func byte(_ input: [UInt8], _ index: Int) -> UInt8? {
        input.indices.contains(index) ? input[index] : nil
    }

    static func quotedPrintable(_ input: [UInt8], header: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var idx = 0
        while idx < input.count {
            let current = input[idx]
            if current == 0x3D {
                if let high = hex(byte(input, idx + 1)), let low = hex(byte(input, idx + 2)) {
                    out.append(high << 4 | low)
                    idx += 3
                } else if byte(input, idx + 1) == 0x0A {
                    idx += 2
                } else if byte(input, idx + 1) == 0x0D, byte(input, idx + 2) == 0x0A {
                    idx += 3
                } else {
                    out.append(current)
                    idx += 1
                }
            } else {
                out.append(header && current == 0x5F ? 0x20 : current)
                idx += 1
            }
        }
        return out
    }
}

/// RFC 2047 encoded words.
enum EncodedWord {
    /// Decodes every encoded word in an unstructured header value. White space between two
    /// encoded words is dropped, as the RFC says.
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var out = ""
        var pendingSpace = ""
        var lastWasEncoded = false
        for token in tokens(input) {
            if token.isSpace {
                pendingSpace += token.text
                continue
            }
            if let word = decodeWord(token.text) {
                if !lastWasEncoded { out += pendingSpace }
                out += word
                lastWasEncoded = true
            } else {
                out += pendingSpace + token.text
                lastWasEncoded = false
            }
            pendingSpace = ""
        }
        return out + pendingSpace
    }

    private struct Token {
        var text: String
        var isSpace: Bool
    }

    private static func tokens(_ input: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var currentIsSpace = false
        for char in input {
            let isSpace = char.isWhitespace
            if !current.isEmpty && isSpace != currentIsSpace {
                result.append(Token(text: current, isSpace: currentIsSpace))
                current = ""
            }
            currentIsSpace = isSpace
            current.append(char)
        }
        if !current.isEmpty { result.append(Token(text: current, isSpace: currentIsSpace)) }
        return result
    }

    private static func decodeWord(_ token: String) -> String? {
        guard token.hasPrefix("=?"), token.hasSuffix("?="), token.count >= 8 else { return nil }
        let inner = token.dropFirst(2).dropLast(2)
        let parts = inner.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let label = parts[0].split(separator: "*", maxSplits: 1).first.map(String.init)
        let payload = Array(parts[2].utf8)
        let bytes: [UInt8]
        switch parts[1].lowercased() {
        case "b": bytes = TransferEncoding.base64(payload)
        case "q": bytes = TransferEncoding.quotedPrintable(payload, header: true)
        default: return nil
        }
        return Charset.decode(Data(bytes), label: label)
    }

    /// Encodes text as B-encoded UTF-8 words of at most 72 characters each.
    static func encode(_ input: String) -> [String] {
        var words: [String] = []
        var chunk: [UInt8] = []
        for scalar in input.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if chunk.count + encoded.count > 45 {
                words.append(word(chunk))
                chunk = []
            }
            chunk += encoded
        }
        if !chunk.isEmpty { words.append(word(chunk)) }
        return words
    }

    private static func word(_ bytes: [UInt8]) -> String {
        "=?UTF-8?B?" + Data(bytes).base64EncodedString() + "?="
    }
}
