// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// The account's signature in a message: put in when it starts, links made of its web addresses,
/// and swapped when another account is chosen.
extension ComposeModel {
    func signatureBlock() -> AttributedString {
        let signature = Self.signature(of: account)
        return signature.isEmpty ? AttributedString("\n\n") : "\n\n" + Self.linked(signature) + "\n"
    }

    /// The signature with each web address in it a link, so it is sent as one, and the default's
    /// words linked to the app's site.
    static func linked(_ signature: String) -> AttributedString {
        var text = AttributedString(signature)
        if let words = DefaultSignature.linkedWords[signature], let link = DefaultSignature.link,
            let range = text.range(of: words) {
            text[range].link = link
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let whole = NSRange(signature.startIndex..., in: signature)
        for match in detector.matches(in: signature, range: whole) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let found = Range(match.range, in: signature),
                let range = Range(found, in: text)
            else { continue }
            text[range].link = url
        }
        return text
    }

    static func signature(of account: Account?) -> String {
        account?.signature.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Another account was chosen: its signature takes the place of the last one's, when that
    /// is still in the body as it was put there.
    func swapSignature(from old: AccountID) {
        guard !isStarting else { return }
        let before = Self.signature(of: accounts.first { $0.id == old })
        let after = Self.signature(of: account)
        guard before != after else { return }
        let text = String(body.characters)
        if !before.isEmpty, let range = body.range(of: "\n\n" + before) {
            body.replaceSubrange(
                range, with: after.isEmpty ? AttributedString("\n\n") : "\n\n" + Self.linked(after))
        } else if before.isEmpty, !after.isEmpty, text.hasPrefix("\n\n") {
            body.insert(Self.linked(after) + "\n", at: body.index(body.startIndex, offsetByCharacters: 2))
        }
    }
}
