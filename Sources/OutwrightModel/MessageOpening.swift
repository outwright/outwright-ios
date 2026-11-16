// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightMIME

/// Whether a message was protected from readers on the way, and whether it could be opened.
public enum Decryption: Sendable, Equatable {
    case none, decrypted, failed
    /// Opened, but what was inside is not a message that can be read.
    case unreadable
}

/// What is known of who a message is from, beyond its From header.
public enum SignatureState: Sendable, Equatable {
    case none
    case valid(verified: Bool)
    case invalid
    case notFromSender
    case unknownKey(fingerprint: String)
}

/// What opening a message found about its protection.
public struct ProtectionFacts: Sendable, Equatable {
    public var decryption: Decryption
    public var signature: SignatureState
    public var resentBy: Address?
    /// The fingerprint of the stored key that made a valid signature; nil for any other signature state.
    public var signer: String?
    /// The From shown came from inside the protection, not from the headers anyone on the way could write.
    public var fromIsProtected: Bool
    /// The From of the headers anyone on the way could write, when the From shown may be another one.
    public var outerFrom: Address?

    public init(
        decryption: Decryption, signature: SignatureState, resentBy: Address?, signer: String? = nil,
        fromIsProtected: Bool = false, outerFrom: Address? = nil
    ) {
        self.decryption = decryption
        self.signature = signature
        self.resentBy = resentBy
        self.signer = signer
        self.fromIsProtected = fromIsProtected
        self.outerFrom = outerFrom
    }
}

/// A stored message as it is read: its content (the decrypted one when it was opened) and what
/// opening it found.
public struct OpenedMessage: Sendable {
    public var message: MIMEMessage
    public var facts: ProtectionFacts?

    public init(message: MIMEMessage, facts: ProtectionFacts? = nil) {
        self.message = message
        self.facts = facts
    }
}

/// A way of opening stored mail that is protected from readers, joined to the shared code at app
/// start. Asked for every stored message; it answers nil for one it does not handle.
public protocol MessageOpening: Sendable {
    func open(_ raw: Data, limits: MIMELimits) -> OpenedMessage?
}

public enum MessageReader {
    /// `opening` first (nil: not handled), else the message read as it is.
    public static func read(_ raw: Data, limits: MIMELimits, opening: (any MessageOpening)?) -> OpenedMessage? {
        if let opened = opening?.open(raw, limits: limits) { return opened }
        guard let parsed = try? MIMEParser.parse(raw, limits: limits) else { return nil }
        return OpenedMessage(message: parsed, facts: nil)
    }

    /// Whether the message's top level is `multipart/encrypted` (RFC 1847), seen from its headers.
    public static func isEncryptedShape(_ raw: Data) -> Bool {
        guard let headers = try? MIMEParser.parseHeaders(Data(raw.prefix(1 << 20))) else { return false }
        return isEncryptedShape(headers)
    }

    /// The same from headers already read.
    public static func isEncryptedShape(_ headers: MIMEMessage) -> Bool {
        headers.rawHeaders.contains {
            $0.name.lowercased() == "content-type"
                && $0.value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("multipart/encrypted")
        }
    }
}
