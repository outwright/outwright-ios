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
    /// A signature that can't be checked, such as one made with a refused algorithm.
    case uncheckable
}

/// What opening a message found about its protection.
public struct ProtectionFacts: Sendable, Equatable {
    public var decryption: Decryption
    public var signature: SignatureState
    public var resentBy: Address?
    /// The fingerprint of the key or certificate that made the signature, as the protection that
    /// opened it can name it (a valid signature, verified or not, and for some protections one whose
    /// certificate was revoked); nil when it names none. Says nothing about trust on its own.
    public var signer: String?
    /// The From shown came from inside the protection, not from the headers anyone on the way could write.
    public var fromIsProtected: Bool
    /// The From of the headers anyone on the way could write, when the From shown may be another one.
    public var outerFrom: Address?
    /// Which protection opened the message, so the shared code shows that protection's screens; nil: not said.
    public var protection: ProtectionID?
    /// The opening vouches that the decrypted content is as its sender wrote it: the encryption
    /// itself is authenticated, or a verified signature of the sender covers what is shown. Without
    /// it, someone on the way may have changed the ciphertext into content that reaches out (EFAIL).
    public var contentIntegrity: Bool

    public init(
        decryption: Decryption, signature: SignatureState, resentBy: Address?, signer: String? = nil,
        fromIsProtected: Bool = false, outerFrom: Address? = nil, protection: ProtectionID? = nil,
        contentIntegrity: Bool = false
    ) {
        self.decryption = decryption
        self.signature = signature
        self.resentBy = resentBy
        self.signer = signer
        self.fromIsProtected = fromIsProtected
        self.outerFrom = outerFrom
        self.protection = protection
        self.contentIntegrity = contentIntegrity
    }

    /// Whether what is shown may fetch remote content (pictures) once the owner asks: always for
    /// content that was not decrypted (nothing secret in it), else only with `contentIntegrity`.
    public var allowsRemoteContent: Bool {
        switch decryption {
        case .none, .failed: true
        case .decrypted, .unreadable: contentIntegrity
        }
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
    /// `account`: the id of the account the stored message is on, when the caller knows it; an
    /// opening that trusts per account trusts nothing account-bound without it.
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage?
}

extension MessageOpening {
    /// Opened with no account known.
    public func open(_ raw: Data, limits: MIMELimits) -> OpenedMessage? {
        open(raw, limits: limits, account: nil)
    }
}

public enum MessageReader {
    /// `opening` first (nil: not handled), else the message read as it is.
    public static func read(_ raw: Data, limits: MIMELimits, opening: (any MessageOpening)?) -> OpenedMessage? {
        read(raw, limits: limits, openings: opening.map { [$0] } ?? [])
    }

    /// The first of `openings` that answers wins, else the message read as it is. `account`: the
    /// stored message's account id, when known.
    public static func read(
        _ raw: Data, limits: MIMELimits, openings: [any MessageOpening], account: String? = nil
    ) -> OpenedMessage? {
        for opening in openings {
            if let opened = opening.open(raw, limits: limits, account: account) { return opened }
        }
        guard let parsed = try? MIMEParser.parse(raw, limits: limits) else { return nil }
        return OpenedMessage(message: parsed, facts: nil)
    }

    /// Whether the message's top level is `multipart/encrypted` (RFC 1847) or an enveloped
    /// `application/pkcs7-mime` (RFC 8551), seen from its headers.
    public static func isEncryptedShape(_ raw: Data) -> Bool {
        guard let headers = try? MIMEParser.parseHeaders(Data(raw.prefix(1 << 20))) else { return false }
        return isEncryptedShape(headers)
    }

    /// The same from headers already read.
    public static func isEncryptedShape(_ headers: MIMEMessage) -> Bool {
        headers.rawHeaders.contains {
            $0.name.lowercased() == "content-type" && isEncryptedContentType($0.value)
        }
    }

    private static func isEncryptedContentType(_ value: String) -> Bool {
        let field = MIMEParser.structuredField(value)
        if field.value == "multipart/encrypted" { return true }
        guard field.value == "application/pkcs7-mime" || field.value == "application/x-pkcs7-mime" else { return false }
        if let kind = field.parameters["smime-type"]?.lowercased() {
            return kind == "enveloped-data" || kind == "authenveloped-data"
        }
        return (field.parameters["name"] ?? "").lowercased().hasSuffix(".p7m")
    }
}
