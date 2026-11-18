// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME

/// The people on the message, and those suggested while one is typed.
extension ComposeModel {
    /// People whose name or address starts with each word of `query` (at a word), most written with
    /// first; not those already on the message nor the owner's own addresses.
    public func suggestions(for query: String) -> [Address] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        let taken = Set((to + cc + bcc).map { $0.email.lowercased() })
        return people.filter { person in
            !taken.contains(person.email.lowercased()) && PeopleIndex.matches(person, wanted)
        }.prefix(8).map { $0 }
    }

    /// Adds people to a list, leaving out those already on the message (in any list, ignoring case).
    public func add(_ people: [Address], to list: RecipientList) {
        var taken = Set((to + cc + bcc).map { $0.email.lowercased() })
        let fresh = people.filter { taken.insert($0.email.lowercased()).inserted }
        switch list {
        case .to: to += fresh
        case .cc: cc += fresh
        case .bcc: bcc += fresh
        }
    }
}
