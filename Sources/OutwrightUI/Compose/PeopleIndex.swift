// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore

/// The people the owner knows, from what the store holds: those mail was exchanged with
/// (recipients of Sent mail and senders of the Inbox, the most frequent first), then the accounts'
/// contacts.
enum PeopleIndex {
    static let scanLimit = 2_000

    /// Correspondents, most mail first, then by address; then contacts' addresses not among them,
    /// in the contacts' order. One entry per address (ignoring case), never the owner's own; a
    /// contact's name fills a correspondent's missing one.
    static func known(_ store: MailStore, accounts: [Account]) -> [Address] {
        let own = Set(accounts.map { $0.email.lowercased() })
        let ids = Set(accounts.map(\.id))
        var contactNames: [String: String] = [:]
        var fromContacts: [Address] = []
        for contact in (try? store.contacts(in: nil, matching: nil)) ?? [] where ids.contains(contact.accountID) {
            let name = contact.details.name
            for email in contact.details.emails {
                let address = email.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = address.lowercased()
                guard !key.isEmpty, !own.contains(key), contactNames[key] == nil else { continue }
                let shown = name.isEmpty || name.lowercased() == key ? nil : name
                contactNames[key] = shown ?? ""
                fromContacts.append(Address(name: shown, email: address))
            }
        }
        var seen = Set<String>()
        var people: [Address] = []
        for var person in ranked(store, accounts: accounts).map(\.address) {
            let key = person.email.lowercased()
            if person.name?.isEmpty ?? true, let name = contactNames[key], !name.isEmpty {
                person.name = name
            }
            seen.insert(key)
            people.append(person)
        }
        for person in fromContacts where seen.insert(person.email.lowercased()).inserted {
            people.append(person)
        }
        return people
    }

    static func ranked(_ store: MailStore, accounts: [Account]) -> [(address: Address, count: Int)] {
        let own = Set(accounts.map { $0.email.lowercased() })
        var counts: [String: (address: Address, count: Int)] = [:]
        func count(_ address: Address) {
            let key = address.email.lowercased()
            guard !key.isEmpty, !own.contains(key) else { return }
            var entry = counts[key] ?? (address, 0)
            if entry.address.name?.isEmpty ?? true, let name = address.name, !name.isEmpty {
                entry.address = address
            }
            entry.count += 1
            counts[key] = entry
        }
        for account in accounts {
            for folder in (try? store.folders(account.id)) ?? [] where folder.kind == .sent || folder.kind == .inbox {
                let query = InboxQuery(scope: .folder(folder.id), inboxClass: nil, filter: .all)
                for row in (try? store.messages(query, limit: scanLimit)) ?? [] {
                    if folder.kind == .sent {
                        (row.to + row.cc).forEach(count)
                    } else {
                        count(row.from)
                    }
                }
            }
        }
        return counts.values.sorted { first, second in
            first.count != second.count ? first.count > second.count : first.address.email < second.address.email
        }
    }

    /// Whether a word of the name, or the address, starts with `prefix` (ignoring case and accents).
    static func matches(_ person: Address, _ prefix: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        if person.email.range(of: prefix, options: options) != nil { return true }
        let words = (person.name ?? "").split { $0.isWhitespace || $0 == "," || $0 == "-" }
        return words.contains { $0.range(of: prefix, options: options) != nil }
    }
}
