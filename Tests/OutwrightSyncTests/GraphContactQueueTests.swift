// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import ImageIO
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// The fake's contacts in the default folder, as JSON objects.
private func serverContacts(_ h: GraphHarness) async throws -> [[String: Any]] {
    try await h.graph.contactsJSON().map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
}

private func defaultBook(_ h: GraphHarness) throws -> AddressBook {
    try #require(try h.store.addressBooks(h.account.id).first { $0.href == "me" })
}

private func only(_ h: GraphHarness) throws -> Contact {
    try #require(try h.store.contacts(in: nil, matching: nil).first)
}

@Suite struct GraphContactQueueTests {
    @Test func newContactIsPosted() async throws {
        try await withGraphContacts { h in
            let syncer = h.syncer()
            try await syncer.sync()
            _ = try h.store.createContact(
                ContactDetails(givenName: "Ny", familyName: "Person", emails: [Labeled(label: "other", value: "ny@example.org")]),
                in: try defaultBook(h).id)
            try await syncer.runChanges()
            let made = try await serverContacts(h)
            #expect(made.count == 1)
            #expect(made.first?["surname"] as? String == "Person")
            let stored = try only(h)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
            #expect(try h.store.remoteETags(stored.addressBookID).count == 1)
        }
    }

    @Test func lostCreateAnswerMakesNoDuplicate() async throws {
        try await withGraphContacts { h in
            let syncer = h.syncer()
            try await syncer.sync()
            _ = try h.store.createContact(ContactDetails(givenName: "Once", familyName: "Only"), in: try defaultBook(h).id)
            await h.graph.dropAnswerOfNextPost()
            _ = try? await syncer.runChanges()
            try await syncer.sync()
            try await syncer.sync()
            #expect(try await serverContacts(h).count == 1)
            #expect(try h.store.contacts(in: nil, matching: nil).count == 1)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func editIsPatchedWithIfMatch() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Björk"))
            try await syncer.runChanges()
            let patch = try #require(await h.graph.requests.last { $0.method == "PATCH" })
            #expect(patch.headers["if-match"] == #"W/"1""#)
            #expect(try await serverContacts(h).first?["surname"] as? String == "Björk")
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func staleEditKeepsBothVersions() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Mine"))
            await h.graph.edit(id, "surname", "Theirs")
            try await syncer.runChanges()
            let contact = try only(h)
            #expect(contact.details.familyName == "Theirs")
            #expect(contact.conflict?.familyName == "Mine")
        }
    }

    @Test func editOfAGoneContactFails() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Late"))
            await h.graph.remove(id)
            try await syncer.runChanges()
            #expect(try only(h).changeFailed)
        }
    }

    @Test func deleteIsSent() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["displayName": "Delete Me"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.deleteContact(try only(h).id)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).isEmpty)
            #expect(try h.store.contacts(in: nil, matching: nil).isEmpty)
        }
    }

    /// A contact held without an etag is still deleted on Graph, without If-Match.
    @Test func deleteWithoutAnETagIsSent() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["displayName": "No Tag"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let id = try only(h).id
            try h.store.updateContact(id, ContactDetails(givenName: "No", familyName: "Tag"))
            let queued = try #require(try h.store.pendingContactChanges(h.account.id).first)
            let href = try #require(queued.href)
            try h.store.contactChangeDone(id, href: href, etag: nil, vcard: Data(), revision: queued.revision)
            try h.store.deleteContact(id)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).isEmpty)
            let delete = try #require(await h.graph.requests.last { $0.method == "DELETE" })
            #expect(delete.headers["if-match"] == nil)
        }
    }

    @Test func deleteOfAGoneContactIsDone() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["displayName": "Gone"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.deleteContact(try only(h).id)
            await h.graph.remove(id)
            try await syncer.runChanges()
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func refusalFailsTheChangeForGood() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Bad"))
            await h.graph.failNext(status: 400)
            try await syncer.runChanges()
            #expect(try only(h).changeFailed)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0)
        }
    }

    @Test func throttlingStopsTheQueueWithoutCounting() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Later"))
            await h.graph.failNext(status: 429)
            await #expect(throws: SyncError.graph(.throttled)) { try await syncer.runChanges() }
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 1)
            #expect(try h.store.contactChangeAttempted(bo.id, revision: -1) == 0)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).first?["surname"] as? String == "Later")
        }
    }

    @Test func unshownPropertiesSurviveAnEdit() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg", "nickName": "Bosse"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Björk"))
            try await syncer.runChanges()
            #expect(try await serverContacts(h).first?["nickName"] as? String == "Bosse")
        }
    }

    @Test func jobTitleGoesBothWays() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg", "jobTitle": "Chief"]))
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try only(h).details
            #expect(details.title == "Chief")
            details.title = "Cook"
            try h.store.updateContact(try only(h).id, details)
            try await syncer.runChanges()
            #expect(try await serverContacts(h).first?["jobTitle"] as? String == "Cook")
        }
    }

    @Test func aPhotoGivenInTheAppGoesToGraph() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9])
            try h.store.updateContact(bo.id, bo.details, photo: jpeg)
            try await syncer.runChanges()
            #expect(await h.graph.photo(of: id) == jpeg)
            try await syncer.sync()
            #expect(try only(h).photo == jpeg, "a sync of the contact keeps the photo")
            _ = try h.store.createContact(ContactDetails(givenName: "Ny"), photo: jpeg, in: try defaultBook(h).id)
            try await syncer.runChanges()
            let made = try #require(try await serverContacts(h).first { $0["givenName"] as? String == "Ny" })
            let newID = try #require(made["id"] as? String)
            #expect(await h.graph.photo(of: newID) == jpeg, "a new contact's photo goes too")
        }
    }

    @Test func anEditAfterAPhotoUploadIsNoConflict() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9])
            try h.store.updateContact(bo.id, bo.details, photo: jpeg)
            try await syncer.runChanges()
            var details = try only(h).details
            details.familyName = "Björk"
            try h.store.updateContact(bo.id, details)
            try await syncer.runChanges()
            let after = try only(h)
            #expect(after.conflict == nil && !after.changeFailed, "the photo's new ETag was kept")
            #expect(try await serverContacts(h).first?["surname"] as? String == "Björk")
            #expect(await h.graph.photo(of: id) == jpeg)
        }
    }

    @Test func aFailedPhotoUploadIsTriedAgainAlone() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9])
            await h.graph.failNextPhoto(status: 500)
            try h.store.updateContact(bo.id, bo.details, photo: jpeg)
            _ = try? await syncer.runChanges()
            #expect(await h.graph.photo(of: id) == nil)
            let before = await h.graph.requests.count
            try await syncer.runChanges()
            let again = await h.graph.requests.dropFirst(before)
            #expect(!again.contains { $0.method == "PATCH" }, "the fields went the first time")
            #expect(await h.graph.photo(of: id) == jpeg)
            let after = try only(h)
            #expect(after.conflict == nil && !after.changeFailed)
            #expect(try h.store.photosToSend(h.account.id).isEmpty)
        }
    }

    @Test func aServerEditDuringThePhotoUploadIsNotLost() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            await h.graph.editAfterNextPhoto("surname", "Elsewhere")
            try h.store.updateContact(bo.id, bo.details, photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 9]))
            try await syncer.runChanges()
            try await syncer.sync()
            #expect(try only(h).details.familyName == "Elsewhere", "the other client's edit comes down")
            #expect(try await serverContacts(h).first?["surname"] as? String == "Elsewhere")
        }
    }

    @Test func aPhotoThatKeepsFailingIsGivenUp() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            for _ in 0..<(ContactSyncer.serverAttempts + 5) { await h.graph.failNextPhoto(status: 500) }
            try h.store.updateContact(bo.id, bo.details, photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 9]))
            for _ in 0..<ContactSyncer.serverAttempts { _ = try? await syncer.runChanges() }
            #expect(try h.store.photosToSend(h.account.id).isEmpty, "given up")
            let puts = await h.graph.requests.filter { $0.method == "PUT" }.count
            #expect(puts == ContactSyncer.serverAttempts)
            _ = try? await syncer.runChanges()
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.count == puts, "no further try")
        }
    }

    /// A photo Graph refused is the owner's still: a card opening doesn't put Graph's photo over
    /// it, the contact shows as failed, and Try again sends it.
    @Test func aGivenUpPhotoIsKeptAndCanBeTriedAgain() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            await h.graph.setPhoto(id, try #require(tinyJPEG()))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let mine = Data([0xFF, 0xD8, 0xFF, 0xE0, 7])
            await h.graph.failNextPhoto(status: 400)
            try h.store.updateContact(bo.id, bo.details, photo: mine)
            _ = try? await syncer.runChanges()
            await syncer.fetchPhoto(bo.id)
            let failed = try only(h)
            #expect(failed.photo == mine, "the owner's photo is not overwritten")
            #expect(failed.changeFailed && failed.photoFailed)
            try h.store.retryFailedPhoto(bo.id)
            try await syncer.runChanges()
            #expect(await h.graph.photo(of: id) == mine)
            let sent = try only(h)
            #expect(!sent.changeFailed && !sent.photoFailed)
        }
    }

    /// Discarding a photo Graph refused takes Graph's photo back.
    @Test func discardingAGivenUpPhotoTakesGraphs() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let theirs = try #require(tinyJPEG())
            await h.graph.setPhoto(id, theirs)
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            await h.graph.failNextPhoto(status: 400)
            try h.store.updateContact(bo.id, bo.details, photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 7]))
            _ = try? await syncer.runChanges()
            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            await syncer.fetchPhoto(bo.id)
            let after = try only(h)
            #expect(after.photo == theirs)
            #expect(!after.changeFailed && !after.photoFailed)
            #expect(try h.store.photosToSend(h.account.id).isEmpty)
        }
    }

    /// A photo waits while the field change it came with is held as a conflict: Apply again sends
    /// both.
    @Test func aPhotoWaitsOutAConflictAndGoesOnApplyAgain() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let mine = Data([0xFF, 0xD8, 0xFF, 0xE0, 7])
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Mine"), photo: mine)
            await h.graph.edit(id, "surname", "Theirs")
            try await syncer.runChanges()
            #expect(try only(h).conflict != nil)
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.isEmpty, "held while the conflict is")
            try h.store.applyConflictAgain(bo.id)
            try await syncer.runChanges()
            #expect(await h.graph.photo(of: id) == mine)
            #expect(try only(h).photo == mine)
        }
    }

    /// Discarding a conflict drops the photo that came with the change: it never reaches Graph.
    @Test func discardingAConflictDropsItsPhoto() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(
                bo.id, ContactDetails(givenName: "Bo", familyName: "Mine"), photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 7]))
            await h.graph.edit(id, "surname", "Theirs")
            try await syncer.runChanges()
            try h.store.discardConflict(bo.id)
            try await syncer.runChanges()
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.isEmpty)
            #expect(await h.graph.photo(of: id) == nil)
            #expect(try h.store.photosToSend(h.account.id).isEmpty)
        }
    }

    /// A photo waits while the field change it came with has failed: Discard drops it unsent.
    @Test func aPhotoBehindAFailedEditWaitsAndDiscardDropsIt() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(
                bo.id, ContactDetails(givenName: "Bo", familyName: "Bad"), photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 7]))
            await h.graph.failNext(status: 400)
            try await syncer.runChanges()
            #expect(try only(h).changeFailed)
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.isEmpty, "held while the edit is failed")
            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            try await syncer.runChanges()
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.isEmpty)
            #expect(await h.graph.photo(of: id) == nil)
        }
    }

    /// An edit after a photo was given up sends the photo again with it.
    @Test func anEditAfterAGivenUpPhotoSendsItAgain() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            let mine = Data([0xFF, 0xD8, 0xFF, 0xE0, 7])
            await h.graph.failNextPhoto(status: 400)
            try h.store.updateContact(bo.id, bo.details, photo: mine)
            _ = try? await syncer.runChanges()
            #expect(try only(h).photoFailed)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Björk"))
            #expect(try !only(h).photoFailed)
            try await syncer.runChanges()
            #expect(await h.graph.photo(of: id) == mine)
            #expect(try await serverContacts(h).first?["surname"] as? String == "Björk")
        }
    }

    @Test func aPhotoWhoseReReadFailsIsNotPutAgain() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            await h.graph.malformNextReadAfterPhoto()
            try h.store.updateContact(bo.id, bo.details, photo: Data([0xFF, 0xD8, 0xFF, 0xE0, 9]))
            _ = try? await syncer.runChanges()
            _ = try? await syncer.runChanges()
            #expect(await h.graph.requests.filter { $0.method == "PUT" }.count == 1)
            try await syncer.sync()
            var details = try only(h).details
            details.givenName = "Bosse"
            try h.store.updateContact(bo.id, details)
            try await syncer.runChanges()
            let after = try only(h)
            #expect(after.conflict == nil && !after.changeFailed, "the next sync took the new tag")
        }
    }

    @Test func graphsPhotoIsReadWhenTheCardOpens() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let jpeg = try #require(tinyJPEG())
            await h.graph.setPhoto(id, jpeg)
            let syncer = h.syncer()
            try await syncer.sync()
            #expect(try only(h).photo == nil, "not read with the listing")
            await syncer.fetchPhoto(try only(h).id)
            #expect(try only(h).photo == jpeg)
            #expect(try h.store.pendingContactChangeCount(h.account.id) == 0, "nothing to send back")
        }
    }

    @Test func discardingAFailedEditRestoresGraphsVersion() async throws {
        try await withGraphContacts { h in
            let id = await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            let bo = try only(h)
            try h.store.updateContact(bo.id, ContactDetails(givenName: "Bo", familyName: "Bad"))
            await h.graph.failNext(status: 400)
            try await syncer.runChanges()
            try ContactRestore.discardFailedChange(bo.id, in: h.store)
            #expect(try only(h).details.familyName == "Berg")
            _ = id
        }
    }

    /// A 429, then a 401 on a token renewed a moment ago: Graph renews it once and goes on; the
    /// edit reaches Graph on the next sync and the account is never asked to sign in again.
    @Test func throttlingThenARefusedTokenIsSurvived() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg"]))
            let syncer = h.syncer()
            try await syncer.sync()
            try h.store.updateContact(try only(h).id, ContactDetails(givenName: "Bo", familyName: "Through"))
            await h.graph.failNext(status: 429)
            await h.graph.failNext(status: 401)
            await #expect(throws: SyncError.graph(.throttled)) { try await syncer.sync() }
            let before = await h.microsoft.oauth.server.requests
            try await syncer.sync()
            #expect(await h.microsoft.oauth.server.requests == before + 1)
            #expect(try await serverContacts(h).first?["surname"] as? String == "Through")
        }
    }

    /// Graph's name for an address (Outlook shows it) is kept when the contact is edited.
    @Test func addressNamesSurviveAnEdit() async throws {
        try await withGraphContacts { h in
            await h.graph.put(graphJSON([
                "givenName": "Bo", "surname": "Berg",
                "emailAddresses": [["name": "Bo at work", "address": "bo@example.org"]],
            ]))
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try only(h).details
            details.familyName = "Björk"
            try h.store.updateContact(try only(h).id, details)
            try await syncer.runChanges()
            let emails = try #require(try await serverContacts(h).first?["emailAddresses"] as? [[String: Any]])
            #expect(emails.first?["name"] as? String == "Bo at work")
            #expect(emails.first?["address"] as? String == "bo@example.org")
        }
    }

    /// A note longer than the app holds is written back whole when the owner didn't touch it.
    @Test func aLongNoteSurvivesAnEditElsewhere() async throws {
        try await withGraphContacts { h in
            let long = String(repeating: "Lund ", count: 20_000)
            await h.graph.put(graphJSON(["givenName": "Bo", "surname": "Berg", "personalNotes": long]))
            let syncer = h.syncer()
            try await syncer.sync()
            var details = try only(h).details
            details.familyName = "Björk"
            try h.store.updateContact(try only(h).id, details)
            try await syncer.runChanges()
            let server = try #require(try await serverContacts(h).first)
            #expect(server["surname"] as? String == "Björk")
            #expect(server["personalNotes"] as? String == long)
        }
    }
}

/// A real JPEG of 4 by 4 pixels: what is read as a photo must read as a picture.
private func tinyJPEG() -> Data? {
    guard let context = CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let image = context.makeImage()
    else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
