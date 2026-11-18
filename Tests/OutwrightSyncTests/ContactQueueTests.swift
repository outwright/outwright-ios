// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import OutwrightStore
@testable import OutwrightSync
import Testing

/// The owner's contact edits go to the server on their own, as a moved message does: no refresh.
@Suite struct ContactQueueTests {
    @Test func anEditReachesTheServerWithoutASync() async throws {
        try await withContacts { h in
            let book = await h.server.addBook("Work")
            await h.server.putCard(card("b", given: "Bo", family: "Berg"), uid: "b", in: book)
            try await h.syncer().sync()
            let coordinator = offlineCoordinator(store: h.store, secrets: h.secrets, actionDelay: .milliseconds(50))
            _ = coordinator

            let bo = try h.contact(named: "Bo Berg")
            var edited = bo.details
            edited.phones = [Labeled(label: "cell", value: "+46 70 000 00 00")]
            try h.store.updateContact(bo.id, edited)

            let reached = await eventually(seconds: 5) {
                guard let text = await h.server.cards(in: book)["b"],
                    let parsed = try? VCardReader.cards(Data(text.utf8)).first
                else { return false }
                return parsed.fields.phones.map(\.value) == ["+46 70 000 00 00"]
            }
            #expect(reached, "the edit reached the server without a sync")
        }
    }
}
