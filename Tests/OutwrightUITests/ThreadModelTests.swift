// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightUI

/// Opens every message as `inner`, decrypted.
private final class DecryptingOpener: MessageOpening {
    let inner: Data
    init(inner: Data) { self.inner = inner }
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        guard let message = try? MIMEParser.parse(inner, limits: limits) else { return nil }
        let facts = ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil)
        return OpenedMessage(message: message, facts: facts)
    }
}

/// Notes the account every opening was told.
private final class AccountNotingOpener: MessageOpening {
    let accounts = Mutex<[String?]>([])
    func open(_ raw: Data, limits: MIMELimits, account: String?) -> OpenedMessage? {
        accounts.withLock { $0.append(account) }
        return nil
    }
}

@MainActor @Suite struct ThreadModelTests {
    @Test func theConversationIsOpenedWithItsAccount() async throws {
        var box = try Mailbox()
        let (anna, ids) = try threadOfThree(&box, bodies: true)
        let opener = AccountNotingOpener()
        box.store.setOpenings([opener])
        let model = ThreadModel(store: box.store, message: ids[0]) { _ in }
        await model.open()
        let accounts = opener.accounts.withLock { $0 }
        #expect(!accounts.isEmpty)
        #expect(accounts.allSatisfy { $0 == anna.id.raw.uuidString })
    }

    private func threadOfThree(_ box: inout Mailbox, bodies: Bool) throws -> (Account, [MessageID]) {
        let anna = try box.addAccount("anna@example.org")
        var ids: [MessageID] = []
        for index in 0..<3 {
            let body = bodies ? try message(subject: "Hej", text: "text \(index)") : nil
            ids.append(
                try box.add(
                    anna, uid: UInt32(index + 1), thread: "t",
                    date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60), body: body))
        }
        return (anna, ids)
    }

    @Test func latestExpandedOthersCollapsed() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[0]) { _ in }
        await model.open()
        #expect(model.items.map(\.id) == ids)
        #expect(model.items.map(\.isExpanded) == [false, false, true])
        #expect(model.items.last?.content?.text?.contains("text 2") == true)
        await model.toggle(ids[0])
        #expect(model.items.first?.isExpanded == true)
        #expect(model.items.first?.content?.text?.contains("text 0") == true)
    }

    @Test func openingFetchesBodyWhenMissing() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: false)
        let store = box.store
        var fetched: [MessageID] = []
        let model = ThreadModel(store: store, message: ids[2]) { id in
            fetched.append(id)
            if let data = try? message(subject: "Hej", text: "fetched") {
                _ = try? store.setBody(data, for: id)
            }
        }
        await model.open()
        #expect(fetched == [ids[2]])
        #expect(model.items.last?.content?.text?.contains("fetched") == true)
    }

    /// An encrypted mail opened before its body was on the phone: fetching the body decrypts it and
    /// the row's subject becomes the inner one, which the conversation then shows in place of "...".
    @Test func subjectIsTheDecryptedOneOnceTheBodyIsFetched() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, subject: "...", body: nil)
        let store = box.store
        store.setOpenings([DecryptingOpener(inner: try message(subject: "The real subject", text: "inside"))])
        let model = ThreadModel(store: store, message: id) { id in
            if let outer = try? message(subject: "...", text: "ciphertext") {
                _ = try? store.setBody(outer, for: id)
            }
        }
        await model.open()
        #expect(model.subject == "The real subject")
    }

    @Test func markedReadOnOpen() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[1]) { _ in }
        await model.open()
        for id in ids {
            #expect(try box.store.message(id)?.isRead == true)
        }
        #expect(try box.store.pendingActions().map(\.action) == ids.map { .setRead($0, true) })
        #expect(model.items.allSatisfy { $0.row.isRead })
    }

    @Test func movingToOtherRemembersTheSender() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        model.setInboxClass(.other)
        #expect(try box.store.overrides()["bo@example.org"] == .other)
        #expect(try box.store.message(ids[2])?.inboxClass == .other)
    }

    @Test func moveToOtherSortsTheSenderNotTheOwner() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = try box.add(anna, uid: 1, thread: "t", from: "bo@example.org", date: Date(timeIntervalSince1970: 1_800_000_000))
        // The owner's own answer is the newest message of the conversation.
        try box.add(anna, .sent, uid: 2, thread: "t", from: anna.email, date: Date(timeIntervalSince1970: 1_800_000_100))
        let model = ThreadModel(store: box.store, message: first) { _ in }
        await model.open()
        model.setInboxClass(.other)
        #expect(try box.store.overrides() == ["bo@example.org": .other])
    }

    @Test func markUnreadMarksTheLatest() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        model.markUnread()
        #expect(try box.store.message(ids[2])?.isRead == false)
    }

    @Test func deleteArchiveAndJunkMoveTheConversationOfTheFolder() async throws {
        for (act, kind) in [("delete", FolderKind.trash), ("archive", .archive), ("junk", .junk)] {
            var box = try Mailbox()
            let (anna, ids) = try threadOfThree(&box, bodies: true)
            let sent = try box.add(anna, .sent, uid: 9, thread: "t")
            let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
            await model.open()
            switch act {
            case "delete": model.delete()
            case "archive": model.archive()
            default: model.junk()
            }
            #expect(model.isGone)
            for id in ids {
                #expect(try box.store.message(id)?.folderID == box.folder(anna, kind).id)
            }
            #expect(try box.store.message(sent)?.folderID == box.folder(anna, .sent).id)
        }
    }

    /// Opened from Junk the conversation says so (its links and pictures are kept shut), and Not junk
    /// moves it to the Inbox; opened anywhere else it is ordinary mail.
    @Test func notJunkMovesTheConversationOfJunkToTheInbox() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let junked = try box.add(anna, .junk, uid: 1, thread: "j", body: try message(subject: "Hej", text: "spam?"))
        let fromInbox = ThreadModel(store: box.store, message: try box.add(anna, uid: 2, thread: "i")) { _ in }
        await fromInbox.open()
        #expect(!fromInbox.isInJunk)
        let model = ThreadModel(store: box.store, message: junked) { _ in }
        await model.open()
        #expect(model.isInJunk)
        model.notJunk()
        #expect(model.isGone)
        #expect(try box.store.message(junked)?.folderID == box.folder(anna, .inbox).id)
    }

    @Test func trashAndJunkCopiesAreHiddenUnlessOpenedThere() async throws {
        var box = try Mailbox()
        let (anna, ids) = try threadOfThree(&box, bodies: true)
        let trashed = try box.add(anna, .trash, uid: 7, thread: "t")
        let junked = try box.add(anna, .junk, uid: 8, thread: "t")
        let fromInbox = ThreadModel(store: box.store, message: ids[0]) { _ in }
        await fromInbox.open()
        #expect(fromInbox.items.map(\.id) == ids)
        let fromTrash = ThreadModel(store: box.store, message: trashed) { _ in }
        await fromTrash.open()
        #expect(Set(fromTrash.items.map(\.id)) == Set(ids + [trashed, junked]))
    }

    @Test func toYouOnlyWhenTheOwnerIsARecipient() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let mine = try box.add(anna, uid: 1, to: ["Anna@Example.org", "cy@example.org"])
        let list = try box.add(anna, uid: 2, to: ["list@example.org", "dan@example.org"])
        let model = ThreadModel(store: box.store, message: mine) { _ in }
        await model.open()
        let item = try #require(model.items.first)
        #expect(model.recipients(of: item) == .you)
        let other = ThreadModel(store: box.store, message: list) { _ in }
        await other.open()
        let otherItem = try #require(other.items.first)
        #expect(other.recipients(of: otherItem) == .others(["list@example.org", "dan@example.org"]))
    }

    @Test func longTextIsShortened() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let text = String(repeating: "a", count: MessageContent.textLimit + 5_000)
        let id = try box.add(anna, uid: 1, body: try message(subject: "Long", text: text))
        let model = ThreadModel(store: box.store, message: id) { _ in }
        await model.open()
        let content = try #require(model.items.first?.content)
        #expect(content.isShortened)
        #expect((content.text?.count ?? 0) <= MessageContent.textLimit)
    }

    @Test func moveTargetsShowSubfoldersUnderTheirParent() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount(
            "anna@example.org", extraFolders: ["Ekonomi/BDD", "BDD/Inbox", "Ekonomi", "BDD"], delimiter: "/")
        let id = try box.add(anna, uid: 1)
        let model = ThreadModel(store: box.store, message: id) { _ in }
        await model.open()
        let others = model.folders().filter { $0.folder.kind == .other }
        #expect(others.map(\.folder.path) == ["BDD", "BDD/Inbox", "Ekonomi", "Ekonomi/BDD"])
        #expect(others.map(\.depth) == [0, 1, 0, 1])
    }

    /// #18: a message is loading until its text is read, not only until its bytes are here.
    @Test func aMessageIsLoadingUntilItsTextIsRead() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        final class Seen: @unchecked Sendable { var loading: [Bool] = [] }
        let seen = Seen()
        var model: ThreadModel?
        let store = box.store
        model = ThreadModel(store: store, message: ids[2], fetchBody: { _ in }) { data in
            await MainActor.run { seen.loading.append(model?.items.last?.isLoading ?? false) }
            return await MessageContent.read(data, store: store)
        }
        await model?.open()
        #expect(seen.loading == [true])
        #expect(model?.items.last?.isLoading == false)
        #expect(model?.items.last?.content != nil)
    }

    /// #18: a failed action is no longer reported once a later one goes through.
    @Test func aFailureIsClearedByTheNextActionThatWorks() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        model.move(to: FolderID(raw: 999_999))
        #expect(model.failed)
        model.toggleFlag()
        #expect(!model.failed)
    }

    /// #18: changing how a sender is sorted clears an earlier failure too.
    @Test func sortingASenderClearsAnEarlierFailure() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        model.move(to: FolderID(raw: 999_999))
        #expect(model.failed)
        model.setInboxClass(.other)
        #expect(!model.failed)
    }

    /// A message closed and opened again while it is read is read once.
    @Test func aMessageReopenedWhileItIsReadIsReadOnce() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        final class Count: @unchecked Sendable {
            var reads = 0
            var model: ThreadModel?
        }
        let count = Count()
        let store = box.store
        count.model = ThreadModel(store: store, message: ids[2], fetchBody: { _ in }) { data in
            let model = await MainActor.run { () -> ThreadModel? in
                count.reads += 1
                return count.reads == 1 ? count.model : nil
            }
            if let model {
                await model.toggle(ids[2])
                await model.toggle(ids[2])
            }
            return await MessageContent.read(data, store: store)
        }
        await count.model?.open()
        #expect(count.reads == 1)
    }

    @Test func theCalendarPartIsNotListedBesideTheMeetingCard() throws {
        let ics = Data("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n".utf8)
        let notes = Attachment(filename: "notes.txt", mimeType: "text/plain", contentID: nil, isInline: false, data: Data("n".utf8))
        let data = try MIMEWriter.write(
            OutgoingMessage(
                from: Address(name: "Maja", email: "maja.ek@example.org"), to: [Address(name: nil, email: "anna@example.org")],
                cc: [], bcc: [], subject: "Invitation", textBody: "You are invited.", htmlBody: nil,
                attachments: [notes], inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000),
                messageID: "i@example.org", calendar: CalendarPart(method: "REQUEST", data: ics)),
            includeBcc: false)
        let content = MessageContent(try MIMEParser.parse(data))
        #expect(content.files.map(\.mimeType).contains("text/calendar"))
        #expect(content.files(besideCard: true).map(\.filename) == ["notes.txt"])
    }

    @Test func aReplyJoinsTheOpenConversationAndKeepsWhatTheOwnerOpened() async throws {
        var box = try Mailbox()
        let (anna, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        await model.toggle(ids[0])
        let reply = try box.add(
            anna, uid: 9, thread: "t", date: Date(timeIntervalSince1970: 1_800_001_000),
            body: try message(subject: "Hej", text: "reply"))
        await model.follow(reply)
        #expect(model.items.map(\.id) == ids + [reply])
        #expect(model.items.first?.isExpanded == true)
        #expect(model.items.last?.isExpanded == true)
        #expect(try box.store.message(reply)?.isRead == true)
    }

    /// Mark unread goes back to the list (on a phone; beside the list the row stays selected).
    @Test func markUnreadAsksToCloseOnPhone() async throws {
        var box = try Mailbox()
        let (_, ids) = try threadOfThree(&box, bodies: true)
        let model = ThreadModel(store: box.store, message: ids[2]) { _ in }
        await model.open()
        #expect(model.markUnread() == .close)
        #expect(try box.store.message(ids[2])?.isRead == false)
    }

    /// The bar's moves and deletes wait out the undo window: nothing reaches the store yet, the
    /// conversation leaves the view, and Undo brings it back as it was.
    @Test func barMovesWaitOutTheUndoWindow() async throws {
        for act in ["delete", "archive", "junk", "move"] {
            var box = try Mailbox()
            let (anna, ids) = try threadOfThree(&box, bodies: true)
            let pending = PendingMail(store: box.store)
            let model = ThreadModel(store: box.store, message: ids[2], pending: pending) { _ in }
            await model.open()
            switch act {
            case "delete": model.delete()
            case "archive": model.archive()
            case "junk": model.junk()
            default: model.move(to: try box.folder(anna, .archive).id)
            }
            #expect(model.isGone, "\(act)")
            #expect(pending.hidden == Set(ids))
            #expect(try box.store.message(ids[2])?.folderID == box.folder(anna, .inbox).id)
            pending.undo()
            #expect(try box.store.message(ids[2])?.folderID == box.folder(anna, .inbox).id)
        }
    }

    /// In Trash, Delete is for good and asks first; anywhere else it doesn't.
    @Test func deleteAsksFirstOnlyInTrash() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let trashed = try box.add(anna, .trash, uid: 1, thread: "x", body: try message(subject: "Hej", text: "old"))
        let kept = try box.add(anna, uid: 2, thread: "y", body: try message(subject: "Hej", text: "new"))
        let inTrash = ThreadModel(store: box.store, message: trashed, pending: PendingMail(store: box.store)) { _ in }
        await inTrash.open()
        let inInbox = ThreadModel(store: box.store, message: kept, pending: PendingMail(store: box.store)) { _ in }
        await inInbox.open()
        #expect(inTrash.deleteNeedsConfirmation)
        #expect(!inInbox.deleteNeedsConfirmation)
        inTrash.deleteForGood()
        #expect(inTrash.isGone)
        #expect(try box.store.message(trashed) == nil)
    }

    /// Decrypted text nobody vouches for (it may have been changed on the way) never fetches
    /// pictures: neither the bar is offered nor does Download pictures take.
    @Test func picturesStayShutOnDecryptedContentWithoutIntegrity() async throws {
        for integrity in [false, true] {
            var box = try Mailbox()
            let anna = try box.addAccount("anna@example.org")
            let html = "Content-Type: text/html\r\n\r\n<img src=\"https://example.org/a.png\">"
            let id = try box.add(anna, uid: 1, body: Data(("Subject: s\r\n" + html).utf8))
            let model = ThreadModel(store: box.store, message: id, fetchBody: { _ in }) { data in
                var content = MessageContent(try? MIMEParser.parse(data))
                content?.facts = ProtectionFacts(
                    decryption: .decrypted, signature: .none, resentBy: nil, contentIntegrity: integrity)
                return content
            }
            await model.open()
            #expect(model.items.last?.content?.hasRemotePictures == true)
            #expect(model.items.last?.content?.offersRemotePictures == integrity)
            model.allowPictures(id)
            #expect(model.items.last?.allowsRemote == integrity)
        }
    }

    /// Reading the message again (a key came in) shows what it says now, without reopening it.
    @Test func reverifyReadsTheMessageAgain() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, body: try message(subject: "Hej", text: "signed"))
        let reads = Counter()
        let model = ThreadModel(store: box.store, message: id, fetchBody: { _ in }) { data in
            var content = MessageContent(try? MIMEParser.parse(data))
            let signature: SignatureState = await reads.next() == 1 ? .unknownKey(fingerprint: "AB") : .valid(verified: false)
            content?.facts = ProtectionFacts(decryption: .none, signature: signature, resentBy: nil)
            return content
        }
        await model.open()
        #expect(model.items.last?.content?.facts?.signature == .unknownKey(fingerprint: "AB"))
        await model.reverify(id)
        #expect(model.items.last?.content?.facts?.signature == .valid(verified: false))
    }
}

private actor Counter {
    var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private extension MessageContent {
    init?(_ message: MIMEMessage?) {
        guard let message else { return nil }
        self.init(message)
    }
}
