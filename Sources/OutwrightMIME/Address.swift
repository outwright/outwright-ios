// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A mailbox: an optional display name and an address. Equality is the address alone, ignoring case.
public struct Address: Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    public static func == (lhs: Address, rhs: Address) -> Bool {
        lhs.email.lowercased() == rhs.email.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(email.lowercased())
    }
}

/// Reads one address-list header (RFC 5322 section 3.4), leniently. Groups are flattened. The
/// display text is kept without its quotes, for a name, and beside it the same text as written
/// (`spec`) or the text in angle brackets, quotes and escapes kept, for an address.
struct AddressScanner {
    private var display = ""
    private var spec = ""
    private var angle = ""
    private var comment = ""
    private var sawAngle = false
    private var displayHasAt = false
    private var inQuote = false
    private var escaped = false
    private var inAngle = false
    private var parenDepth = 0
    private var result: [Address] = []

    static func parseList(_ input: String, maxCount: Int = 1_000) -> [Address] {
        var scanner = AddressScanner()
        for char in input {
            if scanner.result.count >= maxCount { break }
            if scanner.feed(char) { scanner.finishItem() }
        }
        scanner.finishItem()
        return scanner.result
    }

    private mutating func append(_ char: Character) {
        if inAngle {
            angle.append(char)
        } else {
            display.append(char)
            spec.append(char)
            if char == "@" { displayHasAt = true }
        }
    }

    /// A quote or an escape, for the address text only.
    private mutating func keep(_ char: Character) {
        if inAngle {
            angle.append(char)
        } else {
            spec.append(char)
        }
    }

    /// Returns true when the character ends an item.
    private mutating func feed(_ char: Character) -> Bool {
        if escaped {
            escaped = false
            append(char)
        } else if inQuote {
            feedQuoted(char)
        } else if parenDepth > 0 {
            feedComment(char)
        } else {
            return feedPlain(char)
        }
        return false
    }

    private mutating func feedQuoted(_ char: Character) {
        if char == "\\" {
            keep(char)
            escaped = true
        } else if char == "\"" {
            keep(char)
            inQuote = false
        } else {
            append(char)
        }
    }

    private mutating func feedComment(_ char: Character) {
        if char == "(" {
            parenDepth += 1
        } else if char == ")" {
            parenDepth -= 1
        } else if parenDepth > 0 {
            comment.append(char)
        }
    }

    private mutating func feedPlain(_ char: Character) -> Bool {
        switch char {
        case "\"":
            keep(char)
            inQuote = true
        case "(": parenDepth = 1
        case "<":
            inAngle = true
            sawAngle = true
            angle = ""
        case ">": inAngle = false
        case ",", ";":
            if inAngle { angle.append(char) } else { return true }
        case ":":
            if !inAngle && !sawAngle && !displayHasAt {
                display = ""
                spec = ""
            } else { append(char) }
        default: append(char)
        }
        return false
    }

    private mutating func finishItem() {
        defer {
            display = ""
            spec = ""
            angle = ""
            comment = ""
            sawAngle = false
            displayHasAt = false
            inQuote = false
            escaped = false
            inAngle = false
            parenDepth = 0
        }
        let email: String
        var nameText: String
        if sawAngle {
            email = MailAddress.addrSpec(angle)
            nameText = display
        } else {
            email = MailAddress.addrSpec(spec)
            nameText = comment
        }
        guard !email.isEmpty else { return }
        nameText = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameText.isEmpty ? nil : EncodedWord.decode(nameText)
        result.append(Address(name: name, email: email))
    }
}
