// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import CoreGraphics
import Foundation
public import Observation
public import OutwrightModel
import OutwrightStore

/// One place on the alphabet index: a letter, or a dot standing for letters left out for room,
/// which jumps to one of them.
public struct IndexEntry: Hashable, Sendable {
    public let title: String
    /// The section it jumps to.
    public let letter: String
}

/// Whether a new contact has somewhere to go.
public enum ContactAddState: Equatable, Sendable {
    case canAdd
    /// No account has an address book: contacts come with an account that has them.
    case noBook
    /// Every address book there is is read-only.
    case readOnly
}

/// The Contacts tab: every contact of the chosen address books in letter sections.
@Observable @MainActor
public final class ContactsModel {
    /// A to Z, then the Swedish letters, then everything else: the sections where the phone's own
    /// collation can't be asked (`ContactCollation`).
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
    /// Whether some account has an address book a new contact can go to, and if not, why.
    public private(set) var addState = ContactAddState.noBook
    public var canAdd: Bool { addState == .canAdd }
    /// The contact beside the list on a wide screen. When it leaves the list, the next one takes its place.
    public var selected: ContactID?
    /// The cards pushed over the list in one column; a deleted contact's card goes.
    public var path: [ContactID] = []
    /// The list is on screen in one column (or coming back, as a swipe back begins): the tabs show with it.
    public var isListInView = true
    /// The contacts tab has just come back: the list appearing now does so under a pushed card, not as a swipe.
    @ObservationIgnored var isTabReturning = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let collation: ContactCollation

    public init(app: AppModel) {
        self.app = app
        collation = .phone
    }

    /// The index down the right edge for `height` points: the letters that have a section, thinned
    /// out to dots when each would have less than `pointsPerEntry`; none while searching.
    public func indexLetters(height: CGFloat) -> [IndexEntry] {
        guard searchText.isEmpty else { return [] }
        return Self.thinned(sections.map(\.letter), height: height)
    }

    /// The least height of one place on the index, for a finger to find it.
    static let pointsPerEntry: CGFloat = 14

    /// `letters` as they fit in `height`: all of them when they do, else evenly spaced ones (always
    /// the first and the last) with a dot between two that skipped some.
    static func thinned(_ letters: [String], height: CGFloat) -> [IndexEntry] {
        let room = height.isFinite && height > 0 ? Int(min(height / pointsPerEntry, 10_000)) : 0
        if letters.count <= room { return letters.map { IndexEntry(title: $0, letter: $0) } }
        guard let first = letters.first, room > 0 else { return [] }
        guard room >= 3, letters.count >= 2 else { return [IndexEntry(title: first, letter: first)] }
        let kept = (room + 1) / 2
        let last = letters.count - 1
        var result: [IndexEntry] = []
        var previous = 0
        for step in 0..<kept {
            let index = min(step * last / (kept - 1), last)
            if step > 0, index - previous > 1 {
                result.append(IndexEntry(title: "•", letter: letters[(previous + index) / 2]))
            }
            result.append(IndexEntry(title: letters[index], letter: letters[index]))
            previous = index
        }
        return result
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
            for contact in found { byLetter[collation.section(contact), default: []].append(contact) }
            let before = sections.flatMap(\.contacts).map(\.id)
            sections = collation.titles.compactMap { letter in
                byLetter[letter].map { (letter: letter, contacts: $0) }
            }
            selected = PaneSelection.following(selected, old: before, new: sections.flatMap(\.contacts).map(\.id))
            let shownPath = path.filter { (try? app.store.contactIsShown($0)) ?? true }
            if shownPath != path { path = shownPath }
            // The store's accounts, not the app's last read of them: an account change wakes this too.
            let accounts = try app.store.accounts()
            bookGroups = try accounts.compactMap { account in
                let books = try app.store.addressBooks(account.id)
                return books.isEmpty ? nil : (account: account, books: books)
            }
            let writable = Set(accounts.filter { !app.isUnavailable($0) }.map(\.id))
            let takesNew = bookGroups.contains { group in
                writable.contains(group.account.id) && group.books.contains { !$0.isReadOnly }
            }
            addState = takesNew ? .canAdd : bookGroups.isEmpty ? .noBook : .readOnly
            failed = false
        } catch {
            failed = true
        }
    }

    /// The section a contact stands in, from its sort key, in `alphabet`.
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
