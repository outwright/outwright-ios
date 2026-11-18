// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightGraph
import OutwrightModel
import OutwrightStore

extension GraphContactSyncer {
    /// Sends the owner's queued changes in order, with `ContactSyncer`'s outcomes: a refusal for
    /// good fails the change, a 412 keeps both versions, the connection, the sign-in or throttling
    /// stops the queue (the rest stays queued), and server trouble fails a change only after
    /// `ContactSyncer.serverAttempts` tries.
    func runQueue(_ client: GraphClient) async throws(SyncError) {
        try repairUnreadable()
        let pending = try stored { try store.pendingContactChanges(account.id) }.map {
            QueuedContactChange(
                contact: $0.contact, change: $0.change, href: $0.href, etag: $0.etag, vcard: $0.vcard,
                book: $0.book, revision: $0.revision)
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
                guard attempts >= ContactSyncer.serverAttempts else { throw error }
                try failed(change)
            }
        }
        try await sendPhotos(client)
    }

    /// Details that can't be read are read again from the held Graph JSON before anything is sent.
    private func repairUnreadable() throws(SyncError) {
        for found in try stored({ try store.unreadableContacts(account.id) }) {
            let server = ContactRestore.serverVersion(found.vcard)
            try stored {
                try store.repairDetails(found.contact, server?.details ?? ContactDetails(), photo: nil)
            }
        }
    }

    private func send(
        _ change: QueuedContactChange, books: [AddressBook], _ client: GraphClient
    ) async throws(SyncError) {
        switch change.change {
        case .create:
            try await sendCreate(change, books: books, client)
        case .update:
            guard let contact = try stored({ try store.contact(change.contact) }), let id = Self.id(change.href),
                let etag = change.etag, !etag.isEmpty
            else {
                try failed(change)
                return
            }
            var fields = GraphContactMapping.fields(contact.details)
            // The names Graph holds for the addresses go back with them.
            fields.emailNames = change.vcard.flatMap(GraphContacts.fields(json:))?.emailNames ?? [:]
            // A note too long to hold whole, left as it was, goes back whole.
            if let held = change.vcard, let full = GraphContacts.fullNote(json: held, replacing: fields.personalNotes) {
                fields.personalNotes = full
            }
            do throws(SyncError) {
                let updated = try await graph { () async throws(GraphError) in
                    try await client.update(id: id, fields, ifMatch: etag)
                }
                try done(change, folder: Self.folderPath(change.href), updated)
            } catch {
                try await refused(error, change, id: id, client)
            }
        case .delete:
            try await sendDelete(change, books: books, client)
        }
    }

    /// A create carries a create id chosen at its first send and kept. Sent before (its answer
    /// lost), the contact made then is looked for by that id and brought up to date instead of
    /// being made again.
    private func sendCreate(
        _ change: QueuedContactChange, books: [AddressBook], _ client: GraphClient
    ) async throws(SyncError) {
        guard let contact = try stored({ try store.contact(change.contact) }),
            let target = try createTarget(change, books)
        else {
            try failed(change)
            return
        }
        let fields = GraphContactMapping.fields(contact.details)
        do throws(SyncError) {
            let folder = target.folder
            let createID = target.createID
            if target.sentBefore,
                let earlier = try await graph({ () async throws(GraphError) in
                    try await client.find(createID: createID, in: folder)
                }) {
                let updated = try await graph { () async throws(GraphError) in
                    try await client.update(id: earlier.id, fields, ifMatch: earlier.etag)
                }
                try done(change, folder: folder.path, updated)
                return
            }
            let made = try await graph { () async throws(GraphError) in
                try await client.create(fields, createID: createID, in: folder)
            }
            try done(change, folder: folder.path, made)
        } catch {
            guard case let .graph(graph) = error, Self.refusedForGood(graph) else { throw error }
            try failed(change)
        }
    }

    /// The create's folder and id, and whether it was sent before: kept from an earlier send, else
    /// chosen and kept now. Kept as `<folder path>#<create id>` in the store's create slot.
    private func createTarget(
        _ change: QueuedContactChange, _ books: [AddressBook]
    ) throws(SyncError) -> CreateTarget? {
        if let kept = try stored({ try store.createTarget(change.contact) }) {
            guard let kept = Self.createTarget(kept.href), let book = books.first(where: { $0.href == kept.path })
            else { return nil }
            return CreateTarget(
                folder: GraphFolder(path: book.href, name: book.name), createID: kept.createID, sentBefore: true)
        }
        guard let book = books.first(where: { $0.id == change.book }) else {
            return nil
        }
        let createID = UUID().uuidString.lowercased()
        try stored { try store.setCreateTarget(change.contact, href: book.href + "#" + createID, vcard: Data()) }
        return CreateTarget(
            folder: GraphFolder(path: book.href, name: book.name), createID: createID, sentBefore: false)
    }

    struct CreateTarget {
        let folder: GraphFolder
        let createID: String
        let sentBefore: Bool
    }

    /// A delete. A contact never confirmed by Graph is looked for by its create id when it was
    /// sent; one Graph no longer has counts as deleted. One held without an etag is deleted
    /// without If-Match.
    private func sendDelete(
        _ change: QueuedContactChange, books: [AddressBook], _ client: GraphClient
    ) async throws(SyncError) {
        var target: (id: String, etag: String?)?
        if let id = Self.id(change.href) {
            target = (id, change.etag.flatMap { $0.isEmpty ? nil : $0 })
        } else if let kept = try stored({ try store.createTarget(change.contact) }) {
            if let kept = Self.createTarget(kept.href), let book = books.first(where: { $0.href == kept.path }),
                let found = try await graph({ () async throws(GraphError) in
                    try await client.find(createID: kept.createID, in: GraphFolder(path: book.href, name: book.name))
                }) {
                target = (found.id, found.etag)
            }
        }
        guard let target else {
            try finished(change)
            return
        }
        do throws(SyncError) {
            try await graph { () async throws(GraphError) in
                try await client.delete(id: target.id, ifMatch: target.etag)
            }
            try finished(change)
        } catch {
            try await refused(error, change, id: target.id, client)
        }
    }

    /// A refused update or delete: a 412 keeps both versions (a delete Graph no longer has is
    /// done), a 404 fails an update, a refusal for good fails the change; anything else is thrown.
    private func refused(
        _ error: SyncError, _ change: QueuedContactChange, id: String, _ client: GraphClient
    ) async throws(SyncError) {
        guard case let .graph(graph) = error else { throw error }
        switch graph {
        case .preconditionFailed:
            let server = try await self.graph { () async throws(GraphError) in try await client.contact(id: id) }
            guard let server else {
                if change.change == .delete { try finished(change) } else { try failed(change) }
                return
            }
            try stored {
                try store.contactChangeConflicted(
                    change.contact,
                    server: (
                        etag: server.etag, vcard: server.json, details: GraphContactMapping.details(server.fields)))
            }
        case .notFound where change.change == .delete:
            try finished(change)
        case _ where Self.refusedForGood(graph):
            try failed(change)
        default:
            throw error
        }
    }

    /// A refusal no retry changes: 404, or a 4xx other than 408, 423 and 429.
    static func refusedForGood(_ error: GraphError) -> Bool {
        switch error {
        case .notFound, .forbidden, .conflict: true
        case let .status(code): (400..<500).contains(code) && ![408, 423, 429].contains(code)
        default: false
        }
    }

    /// Graph keeps a contact's photo apart: a photo the owner gave goes to `/photo/$value` as a step
    /// of its own, once the contact's fields are on Graph, so a failed upload is tried again alone,
    /// at most `ContactSyncer.serverAttempts` times (counted in `attempts`, free while no field
    /// change is queued); a refusal for good gives it up at once. A photo given up stays the owner's
    /// and marks the contact failed. Graph takes no removal there (the editor offers none).
    private func sendPhotos(_ client: GraphClient) async throws(SyncError) {
        for waiting in try stored({ try store.photosToSend(account.id) }) {
            guard let id = Self.id(waiting.href) else { continue }
            if let photo = waiting.photo {
                do throws(SyncError) {
                    try await graph { () async throws(GraphError) in try await client.setPhoto(id: id, photo) }
                } catch {
                    guard case let .graph(graph) = error, Self.isServerTrouble(error) else { throw error }
                    let attempts = try stored {
                        try store.contactChangeAttempted(waiting.contact, revision: waiting.revision)
                    }
                    if Self.refusedForGood(graph) || attempts >= ContactSyncer.serverAttempts {
                        try stored { try store.photoGivenUp(waiting.contact, revision: waiting.revision) }
                    }
                    continue
                }
                try stored { try store.photoSent(waiting.contact, revision: waiting.revision) }
                await keepMovedTag(waiting, id: id, client)
            } else {
                try stored { try store.photoSent(waiting.contact, revision: waiting.revision) }
            }
        }
    }

    /// The upload moved the contact's ETag: read again, the new tag is kept when nothing else
    /// changed, so the next edit is no false conflict. When another client changed it meanwhile, or
    /// it can't be read, the old tag stays: the next sync reads the contact, and a queued edit meets
    /// its conflict instead of overwriting the other client's change.
    private func keepMovedTag(_ waiting: PhotoToSend, id: String, _ client: GraphClient) async {
        guard let moved = try? await client.contact(id: id),
            let held = waiting.serverCopy.flatMap(GraphContacts.fields(json:)),
            GraphContactMapping.details(moved.fields) == GraphContactMapping.details(held)
        else { return }
        try? store.contactServerCopyMoved(waiting.contact, etag: moved.etag, vcard: moved.json)
    }

    /// Reads the contact's photo from Graph (the owner opened its card): kept unless one of the
    /// owner's waits to be sent. Nothing is said when it can't be read.
    func fetchPhoto(_ contact: ContactID) async {
        guard !retired, let href = try? store.contactHref(contact), let id = Self.id(href),
            let client = try? await client()
        else { return }
        guard let found = try? await client.photo(id: id) else { return }
        try? store.setServerPhoto(contact, ContactPhoto.safe(found))
    }

    private func done(_ change: QueuedContactChange, folder: String, _ contact: GraphContact) throws(SyncError) {
        try stored {
            try store.contactChangeDone(
                change.contact, href: folder + "/contacts/" + contact.id, etag: contact.etag, vcard: contact.json,
                revision: change.revision)
        }
    }

    private func finished(_ change: QueuedContactChange) throws(SyncError) {
        try stored {
            try store.contactChangeDone(change.contact, href: "", etag: nil, vcard: Data(), revision: change.revision)
        }
    }

    private func failed(_ change: QueuedContactChange) throws(SyncError) {
        try stored { try store.contactChangeFailed(change.contact, revision: change.revision) }
    }

    /// The Graph id in a contact's href (`<folder path>/contacts/<id>`).
    static func id(_ href: String?) -> String? {
        guard let href, let range = href.range(of: "/contacts/", options: .backwards) else { return nil }
        let id = String(href[range.upperBound...])
        return id.isEmpty ? nil : id
    }

    static func folderPath(_ href: String?) -> String {
        guard let href, let range = href.range(of: "/contacts/", options: .backwards) else { return "me" }
        return String(href[..<range.lowerBound])
    }
}
