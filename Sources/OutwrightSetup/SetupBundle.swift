// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a setup file carries once opened: named parts, each the JSON of one piece of the setup.
public struct SetupBundle: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public var version: Int
        /// The part's name for the owner, in the language of the device that wrote it: shown by a
        /// reader that does not know the part. Hostile: read through `SetupBundle.label(of:)`.
        public var title: String?
        /// The part's own JSON.
        public var content: Data

        public init(version: Int, title: String? = nil, content: Data) {
            self.version = version
            self.title = title
            self.content = content
        }
    }

    public static let currentVersion = 1
    public static let maxParts = 64
    public static let maxPartSize = 8 * 1024 * 1024
    /// The longest part title or name shown, in UTF-8 octets.
    public static let maxTitle = 256

    public var version: Int
    public var created: Date
    public var device: String
    public var parts: [String: Part]

    public init(version: Int = SetupBundle.currentVersion, created: Date, device: String, parts: [String: Part]) {
        self.version = version
        self.created = created
        self.device = device
        self.parts = parts
    }
}

extension SetupBundle {
    public func sealed(passphrase: Passphrase, parameters: Argon2Parameters = .writer) throws(SetupError) -> Data {
        let sealed = try SymmetricMessage.seal(
            [UInt8](try encoded()), passphrase: [UInt8](passphrase.display.utf8), parameters: parameters)
        return Data(sealed)
    }

    public static func opened(_ file: Data, passphrase: Passphrase) throws(SetupError) -> SetupBundle {
        guard file.count <= SymmetricMessage.maximumSize else { throw .tooLarge }
        let plain = try SymmetricMessage.open([UInt8](file), passphrase: [UInt8](passphrase.display.utf8))
        return try decoded(Data(plain))
    }

    /// The bundle's JSON, as a setup file or the direct transfer carries it.
    public func encoded() throws(SetupError) -> Data {
        guard parts.count <= Self.maxParts, parts.values.allSatisfy({ $0.content.count <= Self.maxPartSize }) else {
            throw .tooLarge
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Whole seconds, in UTC.
        encoder.dateEncodingStrategy = .iso8601
        do { return try encoder.encode(self) } catch { throw .malformed }
    }

    /// A bundle from its JSON, which is hostile: the version and the caps are checked.
    public static func decoded(_ json: Data) throws(SetupError) -> SetupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.date)
        let bundle: SetupBundle
        do { bundle = try decoder.decode(SetupBundle.self, from: json) } catch { throw .malformed }
        guard bundle.version >= 1 else { throw .malformed }
        guard bundle.version <= currentVersion else { throw .unsupported }
        guard bundle.parts.count <= maxParts, bundle.parts.values.allSatisfy({ $0.content.count <= maxPartSize }) else {
            throw .tooLarge
        }
        return bundle
    }

    /// An RFC 3339 date, with or without fractional seconds (another writer may keep them).
    private static func date(_ decoder: any Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        let whole = Date.ISO8601FormatStyle()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard text.utf8.count <= 64,
            let date = (try? whole.parse(text)) ?? (try? fractional.parse(text))
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
        }
        return date
    }

    /// The name of the device that made the bundle as the owner may be shown it: without control and format
    /// characters (a bidirectional override among them), cut to `maxTitle` octets at a character. Possibly empty,
    /// for which the screens show their own word.
    public var shownDevice: String {
        PairingCode.cut(PairingCode.cleaned(device), to: Self.maxTitle)
    }

    /// What the owner is shown for a part: its title when it is a sane one, else its name cut to
    /// `maxTitle` octets, else nil (the screens show their own placeholder). Both are hostile: one
    /// that is empty or holds a control or format character (a bidirectional override among them)
    /// is never shown.
    public func label(of name: String) -> String? {
        if let title = parts[name]?.title, Self.isShowable(title), title.utf8.count <= Self.maxTitle {
            return title
        }
        guard Self.isShowable(name) else { return nil }
        var kept = ""
        for character in name {
            guard kept.utf8.count + character.utf8.count <= Self.maxTitle else { break }
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept
    }

    private static func isShowable(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains {
            [.control, .format].contains($0.properties.generalCategory)
        }
    }
}
