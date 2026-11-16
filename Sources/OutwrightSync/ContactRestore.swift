// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightGraph
public import OutwrightModel
public import OutwrightStore

/// Putting a contact back to the server's version, read from the card the store keeps.
public enum ContactRestore {
    /// The owner gives up a change the server did not take: the server's version comes back, the
    /// change goes. A contact the server never had goes too.
    public static func discardFailedChange(_ id: ContactID, in store: MailStore) throws(StoreError) {
        let server = serverVersion(try store.serverCard(id))
        try store.restoreServerVersion(id, details: server?.details, photo: server?.photo)
    }

    /// The details and inline photo of a stored server copy: a vCard, or a Graph account's
    /// Graph JSON (never mistaken for each other); nil without a readable person card.
    static func serverVersion(_ vcard: Data?) -> (details: ContactDetails, photo: Data?)? {
        guard let vcard else { return nil }
        if let graph = GraphContacts.fields(json: vcard) {
            return (GraphContactMapping.details(graph), nil)
        }
        guard let card = ContactSyncer.parse(vcard), !card.isGroup else { return nil }
        let fields = card.fields
        return (ContactMapping.details(fields), fields.photo)
    }
}
