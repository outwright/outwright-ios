// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// Which signatures are the app's default rather than the owner's: the default stays each device's
/// own (it names the device's app), one the owner wrote comes along. An empty signature is the
/// owner's choice, so it counts as written.
public struct SignatureRule: Sendable {
    /// Whether the signature is the app's default, in any language or form it had.
    public var isDefault: @Sendable (String) -> Bool
    /// This device's default, for an account that comes with the default.
    public var defaultHere: @Sendable () -> String

    public init(isDefault: @escaping @Sendable (String) -> Bool, defaultHere: @escaping @Sendable () -> String) {
        self.isDefault = isDefault
        self.defaultHere = defaultHere
    }

    /// No default: every signature is the owner's and comes along as it is.
    public static let none = SignatureRule(isDefault: { _ in false }, defaultHere: { "" })
}

extension AccountsSetupPart {
    static func signatureID(_ address: String) -> String { "signature:" + address }

    /// The signature an added account gets: this device's default in place of the default.
    func signatureForNew(_ file: String) -> String {
        signatures.isDefault(file) ? signatures.defaultHere() : file
    }

    /// Both signatures the owner's, and different: the owner chooses.
    func signatureDifference(here: Account, file: Account) -> SetupDifference? {
        guard !signatures.isDefault(here.signature), !signatures.isDefault(file.signature),
            here.signature != file.signature
        else { return nil }
        let address = here.email.lowercased()
        return SetupDifference(
            kind: .signature, part: name, label: file.email, id: Self.signatureID(address),
            state: SetupDifference.state(here: here.signature, file: file.signature))
    }

    /// The signature an account here takes from the file, nil to keep its own: the file's when it
    /// is the owner's and here is the default, or when the owner chose the file's.
    func signature(for here: Account, file: Account, replacing: Set<String>) -> String? {
        guard !signatures.isDefault(file.signature), here.signature != file.signature else { return nil }
        if signatures.isDefault(here.signature) { return file.signature }
        return replacing.contains(Self.signatureID(here.email.lowercased())) ? file.signature : nil
    }
}
