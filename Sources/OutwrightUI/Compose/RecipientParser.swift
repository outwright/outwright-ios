// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME

/// Reads what the owner typed in a recipient field.
enum RecipientParser {
    /// `a@b.example` or `Name <a@b.example>`, with separators and spaces around it trimmed; nil
    /// when it is not one address (no `@`, nothing after it, spaces or control characters inside).
    static func address(from typed: String) -> Address? {
        let trimmed = typed.trimmingCharacters(in: CharacterSet(charactersIn: ",; \t"))
        guard !trimmed.isEmpty, trimmed.count <= 320 else { return nil }
        var name: String?
        var email = trimmed
        if trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") {
            let given = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            name = given.isEmpty ? nil : given
            email = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        }
        guard let atSign = email.lastIndex(of: "@"), atSign != email.startIndex,
            email.index(after: atSign) != email.endIndex,
            email[email.index(after: atSign)...].contains("."),
            !email.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                    || "<>,;\"".unicodeScalars.contains($0)
            }),
            !(name ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return Address(name: name, email: email)
    }

    /// Typed or pasted text as addresses: split at commas and semicolons. `rest` holds every entry
    /// that is not an address, as typed (trimmed), in order.
    static func split(_ typed: String) -> (addresses: [Address], rest: [String]) {
        var addresses: [Address] = []
        var rest: [String] = []
        for piece in typed.prefix(100_000).split(whereSeparator: { $0 == "," || $0 == ";" }).prefix(1_000) {
            let entry = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            if let address = address(from: entry) {
                addresses.append(address)
            } else {
                rest.append(entry)
            }
        }
        return (addresses, rest)
    }
}
