// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore

/// One queued change of a contact, as the store hands it out.
struct QueuedContactChange {
    let contact: ContactID
    let change: ContactChange
    let href: String?
    let etag: String?
    let vcard: Data?
    let book: AddressBookID
    let revision: Int
}

extension ContactSyncer {
    /// The server's own trouble tolerated for one change before it is marked failed.
    static let serverAttempts = 10

    /// Sends the owner's queued changes in order. A change the server refuses for good is marked
    /// failed; a 412 keeps both versions; a connection or server failure stops the queue (the
    /// rest stays queued) and is thrown. A change the server failed `serverAttempts` times is
    /// marked failed (kept, shown) and the queue goes on.
    func runQueue(_ client: CardDAVClient) async throws(SyncError) {
        try repairUnreadable()
        let pending = try stored { try store.pendingContactChanges(account.id) }.map {
            QueuedContactChange(
                contact: $0.contact, change: $0.change, href: $0.href, etag: $0.etag, vcard: $0.vcard,
                book: $0.book, revision: $0.revision)
        }
        guard !pending.isEmpty else {
            return
        }
        let books = try stored { try store.addressBooks(account.id) }
        for change in pending {
            do {
                try await send(change, books: books, client)
            } catch {
                guard Self.isServerTrouble(error) else { throw error }
                let attempts = try stored {
                    try store.contactChangeAttempted(change.contact, revision: change.revision)
                }
                guard attempts >= Self.serverAttempts else { throw error }
                try failed(change)
            }
        }
    }

    /// Details that can't be read are read again from the server's card before anything is sent,
    /// so no edit goes out over what only looks empty.
    private func repairUnreadable() throws(SyncError) {
        for found in try stored({ try store.unreadableContacts(account.id) }) {
            let server = ContactRestore.serverVersion(found.vcard)
            try stored {
                try store.repairDetails(found.contact, server?.details ?? ContactDetails(), photo: server?.photo)
            }
        }
    }

    /// A failure on the server's side: not the connection, not the login, not the account's
    /// setup (a redirect off the trusted hosts, plain `http`, an answer past a cap), not this
    /// phone's store. Those stop the queue without counting against the change.
    static func isServerTrouble(_ error: SyncError) -> Bool {
        guard case let .dav(dav) = error else { return false }
        switch dav {
        case .net, .unauthorized, .offDomainRedirect, .plainRefused, .tooLarge:
            return false
        case .notFound, .preconditionFailed, .attendeeChangeRefused, .tokenInvalid, .status, .malformed:
            return true
        }
    }

    private func send(_ change: QueuedContactChange, books: [AddressBook], _ client: CardDAVClient)
        async throws(SyncError) {
        switch change.change {
        case .delete:
            try await sendDelete(change, client)
        case .create:
            try await sendCreate(change, books: books, client)
        case .update:
            guard let contact = try stored({ try store.contact(change.contact) }),
                let href = change.href.flatMap(URL.init(string:)),
                let held = change.vcard.flatMap(Self.parse)
            else {
                // Without the server's card an edit would strip what the app does not show.
                try failed(change)
                return
            }
            let fields = ContactMapping.written(contact.details, photo: contact.photo)
            guard let etag = try await knownETag(change, href, client) else {
                return
            }
            let card = ContactMapping.revised(held.applying(fields), at: Date())
            try await put(card, at: href, ifMatch: etag, change, client)
        }
    }

    /// A create goes to the place and with the UID chosen at its first send. If-None-Match: *
    /// refused there means it is already on the server: when the card there is ours (an earlier
    /// send whose answer was lost) it is brought up to date over its ETag; another card there
    /// fails the change.
    private func sendCreate(
        _ change: QueuedContactChange, books: [AddressBook], _ client: CardDAVClient
    ) async throws(SyncError) {
        guard let contact = try stored({ try store.contact(change.contact) }),
            let (href, base) = try createTarget(change, contact, books)
        else {
            try failed(change)
            return
        }
        let ours = ContactMapping.written(contact.details, photo: contact.photo)
        let card = ContactMapping.revised(base.applying(ours), at: Date())
        let data = VCardWriter.write(card)
        let tag: String?
        do {
            tag = try await client.put(data, at: href, ifMatch: nil)
        } catch .preconditionFailed {
            guard let server = try await fetch(href, client), let held = Self.parse(server.data),
                held.uid == base.uid
            else {
                try failed(change)
                return
            }
            // Ours landed earlier and may have been edited since by another client: our changes go
            // over the server's card, never our first copy.
            let merged = ContactMapping.merged(base: base.fields, ours: ours, server: held.fields)
            try await put(
                ContactMapping.revised(held.applying(merged), at: Date()), at: href, ifMatch: server.etag, change,
                client)
            return
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try await sent(change, href, tag: tag, data, client)
    }

    /// The create's href and starting card: kept from an earlier send, else chosen and kept now.
    private func createTarget(
        _ change: QueuedContactChange, _ contact: Contact, _ books: [AddressBook]
    ) throws(SyncError) -> (URL, VCard)? {
        if let kept = try stored({ try store.createTarget(change.contact) }), let href = URL(string: kept.href),
            let card = Self.parse(kept.vcard) {
            return (href, card)
        }
        guard let book = books.first(where: { $0.id == change.book }), let folder = Self.folder(book.href) else {
            return nil
        }
        let card = ContactMapping.newCard(contact.details)
        let name = (card.uid.map { String($0.dropFirst("urn:uuid:".count)) } ?? UUID().uuidString.lowercased())
        guard let href = URL(string: name + ".vcf", relativeTo: folder)?.absoluteURL else {
            return nil
        }
        try stored {
            try store.setCreateTarget(change.contact, href: href.absoluteString, vcard: VCardWriter.write(card))
        }
        return (href, card)
    }

    private func put(
        _ card: VCard, at href: URL, ifMatch etag: String?, _ change: QueuedContactChange, _ client: CardDAVClient
    ) async throws(SyncError) {
        let data = VCardWriter.write(card)
        let tag: String?
        do {
            tag = try await client.put(data, at: href, ifMatch: etag)
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try await sent(change, href, tag: tag, data, client)
    }

    /// Records a write the server took.
    private func sent(
        _ change: QueuedContactChange, _ href: URL, tag: String?, _ data: Data, _ client: CardDAVClient
    ) async throws(SyncError) {
        var tag = tag
        var held = data
        if tag == nil, let fresh = try? await fetch(href, client) {
            // The server gave no ETag (it may have changed the card as it stored it): read it.
            tag = fresh.etag
            held = fresh.data
        }
        let card = Self.parse(held).map { ContactMapping.details($0.fields) }
        try stored {
            try store.contactChangeDone(
                change.contact, href: href.absoluteString, etag: tag, vcard: held, revision: change.revision,
                card: card)
        }
    }

    private func sendDelete(_ change: QueuedContactChange, _ client: CardDAVClient) async throws(SyncError) {
        guard let text = change.href, let href = URL(string: text) else {
            try await deleteUnanswered(change, client)
            return
        }
        guard let etag = try await knownETag(change, href, client) else {
            return
        }
        do {
            try await client.delete(href, ifMatch: etag)
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try done(change, href: text)
    }

    /// A delete of a contact the server never confirmed. Never sent: dropped here without a
    /// request. Sent but unanswered: the card at the create's place is deleted if it is ours.
    private func deleteUnanswered(_ change: QueuedContactChange, _ client: CardDAVClient) async throws(SyncError) {
        guard let kept = try stored({ try store.createTarget(change.contact) }), let href = URL(string: kept.href),
            let server = try await fetch(href, client)
        else {
            try done(change, href: "")
            return
        }
        guard Self.parse(server.data)?.uid == Self.parse(kept.vcard)?.uid else {
            try done(change, href: "")
            return
        }
        do {
            try await client.delete(href, ifMatch: server.etag)
        } catch {
            try await refused(error, change, href, client)
            return
        }
        try done(change, href: kept.href)
    }

    private func done(_ change: QueuedContactChange, href: String) throws(SyncError) {
        try stored {
            try store.contactChangeDone(change.contact, href: href, etag: nil, vcard: Data(), revision: change.revision)
        }
    }

    /// The ETag to send with an update or delete. When none is held (the server gave none for a
    /// card made here), the server's card stands in only if it is still what was sent; otherwise
    /// it is a conflict, or, if the card is gone, a failed update or a finished delete. Nil: handled.
    private func knownETag(
        _ change: QueuedContactChange, _ href: URL, _ client: CardDAVClient
    ) async throws(SyncError) -> String? {
        if let etag = change.etag, !etag.isEmpty {
            return etag
        }
        guard let server = try await fetch(href, client) else {
            if change.change == .delete {
                try done(change, href: href.absoluteString)
            } else {
                try failed(change)
            }
            return nil
        }
        if server.data == change.vcard {
            return server.etag
        }
        try conflicted(change, server)
        return nil
    }

    /// A refused write: a 412 keeps both versions, a refusal for good marks the change failed,
    /// anything else (the connection, the server's trouble, the login) stops the queue.
    private func refused(
        _ error: DAVError, _ change: QueuedContactChange, _ href: URL, _ client: CardDAVClient
    ) async throws(SyncError) {
        switch error {
        case .preconditionFailed where change.change != .create:
            guard let server = try await fetch(href, client) else {
                if change.change == .delete {
                    try done(change, href: href.absoluteString)
                } else {
                    try failed(change)
                }
                return
            }
            try conflicted(change, server)
        case .preconditionFailed, .notFound:
            try failed(change)
        case let .status(code) where (400..<500).contains(code) && ![408, 423, 429].contains(code):
            try failed(change)
        default:
            throw .dav(error)
        }
    }

    private func failed(_ change: QueuedContactChange) throws(SyncError) {
        try stored { try store.contactChangeFailed(change.contact, revision: change.revision) }
    }

    private func conflicted(_ change: QueuedContactChange, _ server: RemoteCard) throws(SyncError) {
        guard let parsed = Self.parse(server.data) else {
            // The server's version cannot be read: the owner's stays, the change marked failed.
            try failed(change)
            return
        }
        let details = ContactMapping.details(parsed.fields)
        try stored {
            try store.contactChangeConflicted(
                change.contact, server: (etag: server.etag, vcard: server.data, details: details))
        }
    }

    /// The server's card at `href`, nil when it has none.
    private func fetch(_ href: URL, _ client: CardDAVClient) async throws(SyncError) -> RemoteCard? {
        let book = href.deletingLastPathComponent()
        let cards = try await dav { () async throws(DAVError) in try await client.cards(book, hrefs: [href]) }
        return cards.first
    }

    /// A book's address as a folder (ending in a slash), so a card name resolves inside it.
    static func folder(_ href: String) -> URL? {
        URL(string: href.hasSuffix("/") ? href : href + "/")
    }
}
