// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightMIME
public import OutwrightModel
import OutwrightStore
import OutwrightSync

/// A request to open a person card: from a contact, or from an address (and the account of the
/// message it came from).
public struct PersonRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var address: Address?
    public var contact: ContactID?
    public var account: AccountID?

    public init(id: UUID = UUID(), address: Address? = nil, contact: ContactID? = nil, account: AccountID? = nil) {
        self.id = id
        self.address = address
        self.contact = contact
        self.account = account
    }
}

/// The card of one person, built around an address: the contact that has it, or the address alone.
@Observable @MainActor
final class PersonCardModel {
    private(set) var contact: Contact?
    private(set) var latest: [MessageRow] = []
    /// More of the mail with this person than `latest`.
    private(set) var messages: [MessageRow] = []
    /// The attachments of that mail whose bodies are on the phone, newest first, at most 50.
    private(set) var files: [FileHit] = []
    /// The next `eventsShown` events the person organises or attends, then the last `eventsShown` gone.
    private(set) var events: [CalendarEvent] = []
    private(set) var failed = false
    /// How many times the mail with this person has been looked up (it scans all mail).
    @ObservationIgnored private(set) var lookups = 0
    var conflict: ContactDetails? { contact?.conflict }
    /// The contact is in an address book that can be written to.
    private(set) var canEdit = false
    var changeFailed: Bool { contact?.changeFailed ?? false }
    /// The failed change is a photo the server did not take.
    var photoFailed: Bool { contact?.photoFailed ?? false }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let request: PersonRequest

    init(app: AppModel, request: PersonRequest) {
        self.app = app
        self.request = request
    }

    var name: String {
        if let contact { return contact.details.name }
        let given = request.address?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? (request.address?.email ?? "") : given
    }

    var organization: String { contact?.details.organization ?? "" }
    /// The job title.
    var title: String { contact?.details.title ?? "" }

    var emails: [Labeled] {
        if let contact { return contact.details.emails.filter { !$0.value.isEmpty } }
        return request.address.map { [Labeled(label: "", value: $0.email)] } ?? []
    }

    var phones: [Labeled] { contact?.details.phones.filter { !$0.value.isEmpty } ?? [] }

    /// An address that is no contact can become one.
    var canAddContact: Bool { contact == nil && request.address != nil }

    /// The address mail goes to: the one asked for, else the contact's first.
    var mailAddress: Address? {
        let email = request.address?.email ?? emails.first?.value
        return email.map { Address(name: name == $0 ? nil : name, email: $0) }
    }

    var callURL: URL? { phones.first.flatMap { Self.url("tel", $0.value) } }
    var messageURL: URL? { phones.first.flatMap { Self.url("sms", $0.value) } }

    /// Asks for a new message to the person: at once, or once the card sheet has gone (`AppModel.afterCard`).
    func mail() {
        guard let address = mailAddress else { return }
        app.afterCard { [app] in app.compose(.to(address)) }
    }

    /// Changes coming closer together than this are looked at once.
    static let settle = Duration.milliseconds(500)

    /// Reloads when the stored contacts, mail or events change, until the task is cancelled: at once
    /// for the first, then at most once per `settle` (a sync writing mail does so often), with the
    /// mail and events looked up off the main actor. A photo the server keeps apart (Graph) is
    /// asked for once the contact is known.
    func observe() async {
        do {
            var settling = false
            for try await _ in app.store.observeContacts(includingMail: true, includingEvents: true) {
                if settling { try await Task.sleep(for: Self.settle) }
                await refresh()
                if !settling, let id = contact?.id {
                    let sync = app.sync
                    Task { await sync.fetchContactPhoto(id) }
                }
                settling = true
            }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    /// A pull on the card: the contacts of the contact's account are synced again (every account's
    /// for an address no contact holds), as a pull on the list does.
    func pull() async {
        if let account = contact?.accountID {
            await app.sync.refreshContacts(of: account)
            await app.updateAttention()
        } else {
            await app.pullContacts()
        }
    }

    /// Sends the owner's own version again, over the server's newer one.
    func applyAgain() throws(StoreError) {
        guard let id = contact?.id else { return }
        try mutate { () throws(StoreError) in try app.store.applyConflictAgain(id) }
    }

    /// Keeps the server's version and drops the owner's, the photo too (read again from a server
    /// keeping photos apart).
    func discard() throws(StoreError) {
        guard let id = contact?.id else { return }
        try mutate { () throws(StoreError) in try app.store.discardConflict(id) }
        let sync = app.sync
        Task { await sync.fetchContactPhoto(id) }
    }

    /// Gives up the change the server did not take: the server's version comes back, and with it
    /// the photo a server keeping photos apart (Graph) holds.
    func discardFailedChange() throws(StoreError) {
        guard let id = contact?.id else { return }
        try mutate { () throws(StoreError) in try ContactRestore.discardFailedChange(id, in: app.store) }
        let sync = app.sync
        Task { await sync.fetchContactPhoto(id) }
    }

    /// Sends the photo the server did not take once more.
    func retryPhoto() throws(StoreError) {
        guard let id = contact?.id else { return }
        try mutate { () throws(StoreError) in try app.store.retryFailedPhoto(id) }
    }

    /// The contact shows the change at once; its mail and events follow from the observation.
    private func mutate(_ change: () throws(StoreError) -> Void) throws(StoreError) {
        try change()
        do {
            try loadContact()
        } catch {
            failed = true
        }
    }

    func reload() {
        do {
            try loadContact()
            events = try Self.events(involving: addresses, in: app.store, now: app.now())
            show(try Self.mailAndFiles(involving: addresses, in: app.store))
        } catch {
            failed = true
        }
    }

    /// `reload`, with the mail looked up off the main actor.
    private func refresh() async {
        do {
            try loadContact()
            let (store, addresses, now) = (app.store, addresses, app.now())
            events = try await Task.detached { try Self.events(involving: addresses, in: store, now: now) }.value
            show(try await Task.detached { try Self.mailAndFiles(involving: addresses, in: store) }.value)
        } catch {
            failed = true
        }
    }

    private func loadContact() throws {
        contact = try resolve()
        if let contact {
            let books = try app.store.addressBooks(contact.accountID)
            canEdit = books.first { $0.id == contact.addressBookID }.map { !$0.isReadOnly } ?? false
        } else {
            canEdit = false
        }
    }

    private var addresses: Set<String> { Set(emails.map { $0.value.lowercased() }) }

    private func show(_ found: (mail: [MessageRow], files: [FileHit])) {
        lookups += 1
        messages = found.mail
        latest = Array(found.mail.prefix(3))
        files = found.files
        failed = false
    }

    /// The mail with the person and its files (parsed: run it off the main actor).
    nonisolated private static func mailAndFiles(
        involving addresses: Set<String>, in store: MailStore
    ) throws(StoreError) -> (mail: [MessageRow], files: [FileHit]) {
        let rows = try mail(involving: addresses, in: store)
        return (rows, SearchModel.attachmentFiles(store, rows.filter(\.hasAttachment)))
    }

    nonisolated static let eventsShown = 5

    /// The events within a year either way that one of `addresses` organises or attends (in any
    /// case): the coming ones from the soonest, then the past ones from the latest.
    nonisolated private static func events(
        involving addresses: Set<String>, in store: MailStore, now: Date
    ) throws(StoreError) -> [CalendarEvent] {
        guard !addresses.isEmpty else { return [] }
        let year: TimeInterval = 366 * 86_400
        let found = try store.occurrences(
            from: now.addingTimeInterval(-year), to: now.addingTimeInterval(year), in: nil
        ).filter { event in
            let details = event.occurrence.details
            return details.organizer.map { addresses.contains($0.lowercased()) } == true
                || details.attendees.contains { addresses.contains($0.email.lowercased()) }
        }
        let coming = found.filter { $0.occurrence.end > now }.sorted { $0.occurrence.start < $1.occurrence.start }
        let gone = found.filter { $0.occurrence.end <= now }.sorted { $0.occurrence.start > $1.occurrence.start }
        return Array(coming.prefix(eventsShown)) + Array(gone.prefix(eventsShown))
    }

    /// The newest 50 messages from, to or copying any of `addresses`.
    nonisolated private static func mail(
        involving addresses: Set<String>, in store: MailStore
    ) throws(StoreError) -> [MessageRow] {
        var found: [MessageID: MessageRow] = [:]
        for email in addresses {
            for row in try store.messages(involving: email, limit: 50) { found[row.id] = row }
        }
        return found.values.sorted { ($0.date, $0.id.raw) > ($1.date, $1.id.raw) }.prefix(50).map { $0 }
    }

    private func resolve() throws -> Contact? {
        if let id = request.contact { return try app.store.contact(id) }
        guard let email = request.address?.email else { return nil }
        let found = try app.store.contacts(withEmail: email)
        return found.first { $0.accountID == request.account } ?? found.first
    }

    /// `tel:` and `sms:` carry only dialling characters, so a stored value can't smuggle in more.
    static func url(_ scheme: String, _ number: String) -> URL? {
        let allowed = Set("0123456789+*#,;")
        let digits = String(number.filter { allowed.contains($0) }.prefix(64))
        guard digits.contains(where: \.isNumber) else { return nil }
        return URL(string: "\(scheme):\(digits)")
    }
}
