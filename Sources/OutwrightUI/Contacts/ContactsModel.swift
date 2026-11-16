// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import Observation
public import OutwrightModel
import OutwrightStore

/// The Contacts tab: every contact of the chosen address books in letter sections.
@Observable @MainActor
public final class ContactsModel {
    /// A to Z, then the Swedish letters, then everything else.
    public static let alphabet: [String] =
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) } + ["Å", "Ä", "Ö", "#"]

    public var searchText = "" {
        didSet { if searchText != oldValue { reload() } }
    }
    /// The address books shown; nil means all.
    public var shownBooks: Set<AddressBookID>? {
        didSet { if shownBooks != oldValue { reload() } }
    }
    public private(set) var sections: [(letter: String, contacts: [Contact])] = []
    public private(set) var bookGroups: [(account: Account, books: [AddressBook])] = []
    public private(set) var failed = false
    /// The contact beside the list on a wide screen. When it leaves the list, the next one takes its place.
    public var selected: ContactID?

    /// The letters of the index on the right.
    public var letters: [String] { Self.alphabet }

    @ObservationIgnored private let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    /// Reloads when the stored contacts change (a sync finished, an edit), until the task is cancelled.
    public func observe() async {
        await watch(app.store.observeContacts())
    }

    /// Reloads for each value of the stream; an error other than the view going away shows as `failed`.
    func watch(_ stream: AsyncThrowingStream<Void, any Error>) async {
        do {
            for try await _ in stream { reload() }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    public func reload() {
        do {
            let found = try app.store.contacts(in: shownBooks, matching: searchText)
            var byLetter: [String: [Contact]] = [:]
            for contact in found { byLetter[Self.letter(of: contact), default: []].append(contact) }
            let before = sections.flatMap(\.contacts).map(\.id)
            sections = Self.alphabet.compactMap { letter in
                byLetter[letter].map { (letter: letter, contacts: $0) }
            }
            selected = PaneSelection.following(selected, old: before, new: sections.flatMap(\.contacts).map(\.id))
            bookGroups = try app.accounts.compactMap { account in
                let books = try app.store.addressBooks(account.id)
                return books.isEmpty ? nil : (account: account, books: books)
            }
            failed = false
        } catch {
            failed = true
        }
    }

    /// The section a contact stands in, from its sort key.
    static func letter(of contact: Contact) -> String {
        guard let first = contact.details.sortKey.unicodeScalars.first else { return "#" }
        switch first {
        case "a"..."z": return String(first).uppercased()
        case "{": return "Å"
        case "|": return "Ä"
        case "}": return "Ö"
        default: return "#"
        }
    }
}
