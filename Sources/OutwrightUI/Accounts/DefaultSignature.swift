// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightModel
public import OutwrightStore
public import OutwrightSync

/// The signature an account has until its owner writes one of their own.
@MainActor
public enum DefaultSignature {
    static let filledKey = "defaultSignatureFilled"

    public nonisolated static var text: String {
        String(localized: "Sent from Outwright for iOS", bundle: .module)
    }

    /// Where the default's link goes.
    static let link = URL(string: "https://outwright.app")

    /// The default in each language it ships in, with the words that carry the link: a message
    /// links them whatever language the phone has now.
    nonisolated static let linkedWords: [String: String] = [
        "Sent from Outwright for iOS": "Outwright for iOS",
        "Skickat från Outwright för iOS": "Outwright för iOS"
    ]

    /// The default as it read before, in each language it shipped in; an account still carrying
    /// it gets today's.
    nonisolated static let old: Set<String> = [
        "Sent from Outwright for iOS\nhttps://github.com/outwright/outwright-ios",
        "Skickat från Outwright för iOS\nhttps://github.com/outwright/outwright-ios"
    ]

    /// The default as a setup brings it: never from one device to another, each keeps its own.
    /// Any form the default had, in any language it shipped in, is the default.
    public nonisolated static var setupRule: SignatureRule {
        SignatureRule(
            isDefault: { signature in
                let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == text || linkedWords.keys.contains(trimmed) || old.contains(trimmed)
            },
            defaultHere: { text })
    }

    /// Accounts whose signature is still an earlier default get today's; one the owner wrote stays.
    public static func replaceOld(store: MailStore) {
        guard let accounts = try? store.accounts() else { return }
        for var account in accounts where old.contains(ComposeModel.signature(of: account)) {
            account.signature = text
            guard (try? store.save(account)) != nil else { return }
        }
    }

    /// Accounts added before the default existed and still without a signature get it, once:
    /// a signature the owner clears afterwards stays cleared.
    public static func fillEmpty(store: MailStore, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: filledKey), let accounts = try? store.accounts() else { return }
        for var account in accounts where ComposeModel.signature(of: account).isEmpty {
            account.signature = text
            guard (try? store.save(account)) != nil else { return }
        }
        defaults.set(true, forKey: filledKey)
    }
}
