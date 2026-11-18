// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What the QR code of a direct transfer holds: who shows it, the secret both sides prove they hold, the service the
/// showing device listens on, and its name. The text is read from a camera and is hostile.
///
/// Binary: `version(1) role(1) secret(32) serviceLength(1) service deviceLength(1) device`. Text: `OWSETUP:` and the
/// binary in base64url without padding.
public struct PairingCode: Sendable, Equatable {
    /// What the device that shows the code does.
    public enum Role: UInt8, Sendable {
        case receives = 1
        case sends = 2
    }

    public static let currentVersion: UInt8 = 1
    public static let secretSize = 32
    /// The longest service name, in UTF-8 octets (a DNS-SD instance name).
    public static let maxService = 63
    /// What a version 1 reader accepts as the service: what `generate` makes.
    static let serviceLength = 12
    /// The longest device name, in UTF-8 octets.
    public static let maxDevice = 64
    /// The longest text read: more than any code of this version needs.
    public static let maxText = 256
    static let prefix = "OWSETUP:"

    public var version: UInt8
    public var role: Role
    public var secret: [UInt8]
    public var service: String
    /// For display: a code read from text holds the name cleaned of control and format characters.
    public var device: String
    /// The octets a code was read from, with the fields they gave: the prologue both sides must agree on, though the
    /// device name shown is cleaned.
    private var origin: Origin?

    private struct Origin: Sendable {
        var version: UInt8
        var role: Role
        var secret: [UInt8]
        var service: String
        var device: String
        var octets: [UInt8]

        func matches(_ code: PairingCode) -> Bool {
            version == code.version && role == code.role && secret == code.secret && service == code.service
                && device == code.device
        }
    }

    public init(
        version: UInt8 = PairingCode.currentVersion, role: Role, secret: [UInt8], service: String, device: String
    ) {
        self.version = version
        self.role = role
        self.secret = secret
        self.service = service
        self.device = device
    }

    /// A new code: a random secret and service name, and the device's name cut to `maxDevice` octets.
    public static func generate(role: Role, device: String) -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let secret = (0..<secretSize).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let service = (0..<serviceLength / 2).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }.joined()
        return PairingCode(role: role, secret: secret, service: service, device: cut(device, to: maxDevice))
    }

    /// The code's octets: those it was read from while its fields are as read, else made from its fields, with the
    /// service and device names cut to their caps at a character.
    public var binary: [UInt8] {
        if let origin, origin.matches(self) { return origin.octets }
        let service = Array(Self.cut(service, to: Self.maxService).utf8)
        let device = Array(Self.cut(device, to: Self.maxDevice).utf8)
        return [version, role.rawValue] + secret + [UInt8(truncatingIfNeeded: service.count)] + service
            + [UInt8(truncatingIfNeeded: device.count)] + device
    }

    public var text: String {
        Self.prefix
            + Data(binary).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads a code's text. A newer version is `.unsupported`; anything else that is not a code is `.malformed`.
    public init(text: String) throws(SetupError) {
        guard text.utf8.count <= Self.maxText, text.utf8.starts(with: Self.prefix.utf8) else { throw .malformed }
        guard var body = String(text.utf8.dropFirst(Self.prefix.utf8.count)) else { throw .malformed }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !body.isEmpty, body.allSatisfy({ alphabet.contains($0) }), body.count % 4 != 1 else { throw .malformed }
        body = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { throw .malformed }
        self = try Self.read([UInt8](data))
    }

    private static func read(_ binary: [UInt8]) throws(SetupError) -> PairingCode {
        var reader = binary[...]
        guard let version = reader.popFirst(), version >= 1 else { throw .malformed }
        guard version <= currentVersion else { throw .unsupported }
        guard let roleOctet = reader.popFirst(), let role = Role(rawValue: roleOctet) else { throw .malformed }
        guard reader.count >= secretSize else { throw .malformed }
        let secret = Array(reader.prefix(secretSize))
        reader = reader.dropFirst(secretSize)
        let service = try string(from: &reader, cap: maxService)
        let device = try string(from: &reader, cap: maxDevice)
        guard reader.isEmpty, service.utf8.count == serviceLength,
            service.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { throw .malformed }
        var code = PairingCode(version: version, role: role, secret: secret, service: service, device: cleaned(device))
        code.origin = Origin(
            version: version, role: role, secret: secret, service: service, device: code.device, octets: binary)
        return code
    }

    /// A length octet and that many octets of UTF-8.
    private static func string(from reader: inout ArraySlice<UInt8>, cap: Int) throws(SetupError) -> String {
        guard let length = reader.popFirst().map(Int.init), length <= cap, reader.count >= length else {
            throw .malformed
        }
        guard let text = String(validating: reader.prefix(length), as: UTF8.self) else { throw .malformed }
        reader = reader.dropFirst(length)
        return text
    }

}

extension PairingCode {
    /// Two codes are equal when their octets are: a code read from another's text equals it.
    public static func == (lhs: PairingCode, rhs: PairingCode) -> Bool {
        lhs.binary == rhs.binary
    }
}

extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The code without its secret, for logs.
    public var description: String {
        "PairingCode(version: \(version), role: \(role), service: \(service), device: \(device), secret: redacted)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["version": version, "role": role, "service": service, "device": device, "secret": "redacted"])
    }
}

extension PairingCode {
    /// `text` without control and format characters (bidirectional overrides among them): a hostile name as it may be
    /// shown. Possibly empty.
    static func cleaned(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(
            contentsOf: text.unicodeScalars.filter { ![.control, .format].contains($0.properties.generalCategory) })
        return String(kept)
    }

    /// `text` cut to at most `octets` UTF-8 octets, at a character.
    static func cut(_ text: String, to octets: Int) -> String {
        var kept = ""
        var count = 0
        for character in text {
            let size = character.utf8.count
            guard size <= octets - count else { break }
            kept.append(character)
            count += size
        }
        return kept
    }
}
