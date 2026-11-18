// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor @Suite struct ComposeModelTests {
    private let swedish = Locale(identifier: "sv_SE")

    private func received(_ box: Mailbox, _ account: Account, subject: String, text: String) throws -> MessageID {
        try box.add(account, uid: 1, from: "bo@example.org", subject: subject, body: try message(subject: subject, text: text))
    }

    private func draftRows(_ box: Mailbox, _ account: Account) throws -> [MessageRow] {
        let drafts = try box.folder(account, .drafts)
        return try box.store.messages(InboxQuery(scope: .folder(drafts.id), inboxClass: nil, filter: .all), limit: 50)
    }

    @Test func replyQuotesAndPrefixesSv() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.signature = "Anna Andersson"
        try box.store.save(anna)
        let original = try received(box, anna, subject: "Möte", text: "Ses i morgon klockan tio.")
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(original)), store: box.store, accounts: [anna], locale: swedish)
        #expect(model.subject == "Sv: Möte")
        #expect(model.to.map(\.email) == ["bo@example.org"])
        let text = shownText(model)
        let signature = try #require(text.range(of: "Anna Andersson"))
        let quote = try #require(text.range(of: "Ses i morgon klockan tio."))
        #expect(signature.upperBound <= quote.lowerBound)

        let again = try received(box, anna, subject: "Sv: Möte", text: "Bra.")
        let second = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(again)), store: box.store, accounts: [anna], locale: swedish)
        #expect(second.subject == "Sv: Möte")
        let english = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(original)), store: box.store, accounts: [anna],
            locale: Locale(identifier: "en_GB"))
        #expect(english.subject == "Re: Möte")
    }

    @Test func replyFromAccountMessageCameTo() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let carl = try box.addAccount("carl@example.org")
        let original = try received(box, carl, subject: "Hej", text: "Hej Carl")
        let reply = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(original)), store: box.store, accounts: [anna, carl],
            accountInView: anna.id)
        #expect(reply.from == carl.id)
        let fresh = ComposeModel(
            request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, carl], accountInView: carl.id)
        #expect(fresh.from == carl.id)
        let inAll = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, carl])
        #expect(inAll.from == anna.id)
    }

    @Test func closingWithChangesSavesDraft() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let untouched = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        try untouched.close()
        #expect(try draftRows(box, anna).isEmpty)
        #expect(try box.store.pendingActions().isEmpty)

        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.to = [Address(name: "Bo", email: "bo@example.org")]
        model.subject = "Utkast"
        model.body = AttributedString("Hej Bo")
        try model.close()
        let rows = try draftRows(box, anna)
        #expect(rows.map(\.subject) == ["Utkast"])
        let draft = try #require(rows.first)
        #expect(draft.uid == 0)
        #expect(try box.store.pendingActions().map(\.action) == [.saveDraft(draft.id)])
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.to.map(\.email) == ["bo@example.org"])
        #expect(parsed.textBody?.contains("Hej Bo") == true)

        // Opening the draft again and closing it unchanged saves nothing more.
        let reopened = await ComposeModel.make(request: ComposeRequest(kind: .draft(draft.id)), store: box.store, accounts: [anna])
        #expect(reopened.subject == "Utkast")
        try reopened.close()
        #expect(try box.store.pendingActions().count == 1)
    }

    @Test func suggestionsFromCorrespondents() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let sent = try box.folder(anna, .sent)
        let row = MessageRow(
            id: MessageID(raw: 0), accountID: anna.id, folderID: sent.id, uid: 9, threadID: ThreadID(raw: "s9"),
            from: Address(name: nil, email: anna.email), to: [Address(name: "Carl Svensson", email: "carl@example.org")],
            cc: [], subject: "Lunch", preview: "", date: Date(timeIntervalSince1970: 1_800_000_000), isRead: true,
            isFlagged: false, hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: false,
            threadCount: 1)
        _ = try box.store.upsert([row])
        try box.add(anna, uid: 2, from: "dora@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        #expect(model.suggestions(for: "car").map(\.email) == ["carl@example.org"])
        #expect(model.suggestions(for: "Svens").first?.name == "Carl Svensson")
        #expect(model.suggestions(for: "dor").map(\.email) == ["dora@example.org"])
        #expect(model.suggestions(for: "").isEmpty)
    }

    @Test func sendQueuesSendAction() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        #expect(throws: ComposeError.noRecipients) { try model.send() }
        model.to = [Address(name: nil, email: "bo@example.org")]
        model.bcc = [Address(name: nil, email: "hemlig@example.org")]
        model.subject = "Skickas"
        try model.send()
        let draft = try #require(try draftRows(box, anna).first)
        #expect(try box.store.pendingActions().map(\.action) == [.send(draftID: draft.id)])
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.bcc.map(\.email) == ["hemlig@example.org"])
        try model.close()
        #expect(try box.store.pendingActions().count == 1)
    }

    @Test func typedRecipientsAreReadAsAddresses() {
        #expect(RecipientParser.address(from: " bo@example.org, ") == Address(name: nil, email: "bo@example.org"))
        let named = RecipientParser.address(from: "Bo Ek <bo@example.org>")
        #expect(named?.email == "bo@example.org")
        #expect(named?.name == "Bo Ek")
        #expect(RecipientParser.address(from: "bo") == nil)
        #expect(RecipientParser.address(from: "bo@") == nil)
        #expect(RecipientParser.address(from: "a b@example.org") == nil)
        #expect(RecipientParser.address(from: "bo@example.org\r\nBcc: x@example.org") == nil)
    }

    private func mail(
        from: Address, to: [Address], cc: [Address] = [], replyTo: [Address] = [], subject: String = "Plan",
        html: String? = nil
    ) throws -> Data {
        var data = try MIMEWriter.write(
            OutgoingMessage(
                from: from, to: to, cc: cc, bcc: [], subject: subject, textBody: "Original text", htmlBody: html,
                attachments: [], inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000),
                messageID: "orig@example.org"),
            includeBcc: false)
        if !replyTo.isEmpty {
            let header = "Reply-To: " + replyTo.map(\.email).joined(separator: ", ") + "\r\n"
            data = Data(header.utf8) + data
        }
        return data
    }

    private func address(_ email: String) -> Address { Address(name: nil, email: email) }

    @Test func closeReportsAFailureAndStaysOpen() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        try box.store.replaceFolders([inbox], for: anna.id)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Kept?"
        #expect(throws: ComposeError.noDraftsFolder) { try model.close() }
        #expect(!model.isFinished)
        model.discard()
        #expect(model.isFinished)
        #expect(try box.store.pendingActions().isEmpty)
    }

    @Test func typedRecipientsOfAFailedSendAreNotAddedAgain() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let drafts = try box.folder(anna, .drafts)
        try box.store.replaceFolders([inbox], for: anna.id)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        let typed: [RecipientList: String] = [.to: "bo@example.org", .cc: "carl@example.org"]
        #expect(throws: ComposeError.noDraftsFolder) { try model.send(typed: typed) }
        #expect(model.to.isEmpty)
        #expect(model.cc.isEmpty)
        try box.store.replaceFolders([inbox, drafts], for: anna.id)
        try model.send(typed: typed)
        #expect(model.to.map(\.email) == ["bo@example.org"])
        #expect(model.cc.map(\.email) == ["carl@example.org"])
    }

    @Test func typedRecipientsOfASendThePhoneCouldNotQueueAreNotAddedAgain() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        _ = try box.folder(anna, .drafts)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        try box.store.refuseQueuedActions(true)
        let typed: [RecipientList: String] = [.to: "bo@example.org", .bcc: "carl@example.org"]
        #expect(throws: ComposeError.store) { try model.send(typed: typed) }
        #expect(model.to.isEmpty)
        #expect(model.bcc.isEmpty)
        try box.store.refuseQueuedActions(false)
        try model.send(typed: typed)
        #expect(model.to.map(\.email) == ["bo@example.org"])
        #expect(model.bcc.map(\.email) == ["carl@example.org"])
    }

    @Test func aDraftNotKeptOnTheWayToTheBackgroundIsSaid() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.store.replaceFolders([try box.folder(anna, .inbox)], for: anna.id)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.keepInTheBackground()
        #expect(model.keepFailure == nil, "nothing written, nothing to keep")
        model.subject = "Kept?"
        model.keepInTheBackground()
        #expect(model.keepFailure == .noDraftsFolder)
        #expect(!model.isFinished)
    }

    @Test func closingAsksWhenTheDraftCannotBeKept() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let drafts = try box.folder(anna, .drafts)
        try box.store.replaceFolders([inbox], for: anna.id)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.subject = "Kept?"
        #expect(!model.closeAsked())
        #expect(model.keepFailure == .noDraftsFolder)
        try box.store.replaceFolders([inbox, drafts], for: anna.id)
        #expect(model.closeAsked())
        #expect(model.isFinished)
    }

    @Test func aFileIsAttachedOnlyWithinTheRoomLeft() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        let big = ComposeModel.maxAttachmentBytes - 10
        #expect(model.attach(
            Attachment(filename: "a.bin", mimeType: "application/octet-stream", contentID: nil, isInline: false,
                       data: Data(count: big))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: 11).write(to: url)
        #expect(model.attachFile(url, filename: "b.txt", mimeType: "text/plain") == .tooLarge)
        #expect(model.attachments.count == 1)
        try Data(repeating: 0x41, count: 10).write(to: url)
        #expect(model.attachFile(url, filename: "b.txt", mimeType: "text/plain") == nil)
        #expect(model.attachments.map(\.filename) == ["a.bin", "b.txt"])
        let missing = url.appendingPathExtension("gone")
        #expect(model.attachFile(missing, filename: "c.txt", mimeType: "text/plain") == .unreadable)
        #expect(model.attachments.count == 2)
    }

    @Test func defaultAccountIsUsedForNewMailInAllAccounts() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@other.example")
        let all = ComposeModel(
            request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, bo], defaultAccount: bo.id)
        #expect(all.from == bo.id)
        // An account in view wins over the default; one that is gone is not used.
        let inView = ComposeModel(
            request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, bo], accountInView: anna.id,
            defaultAccount: bo.id)
        #expect(inView.from == anna.id)
        let gone = ComposeModel(
            request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, bo], defaultAccount: AccountID())
        #expect(gone.from == anna.id)
    }

    @Test func messageIDFollowsTheChosenAccount() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let bo = try box.addAccount("bo@other.example")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, bo])
        model.subject = "Vem?"
        model.from = bo.id
        try model.close()
        let draft = try #require(try box.store.messages(
            InboxQuery(scope: .folder(box.folder(bo, .drafts).id), inboxClass: nil, filter: .all), limit: 5).first)
        #expect(draft.messageIDHeader?.hasSuffix("@other.example") == true)
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.messageID?.hasSuffix("@other.example") == true)
    }

    @Test func replyToOwnSentMessageGoesToItsRecipients() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let sent = try box.add(
            anna, .sent, uid: 3, from: anna.email,
            body: try mail(from: address(anna.email), to: [address("carl@example.org"), address("dora@example.org")]))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .reply(sent)), store: box.store, accounts: [anna])
        #expect(model.to.map(\.email) == ["carl@example.org", "dora@example.org"])
    }

    /// Mail between two accounts on the same phone: the reply goes to the other account, as to anyone.
    @Test func replyToMailFromAnotherOwnAccountGoesToThatAccount() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let carl = try box.addAccount("carl@example.org")
        let id = try box.add(
            carl, uid: 6, from: anna.email,
            body: try mail(from: address(anna.email), to: [address(carl.email)], cc: [address("dora@example.org")]))
        let reply = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna, carl])
        #expect(reply.from == carl.id)
        #expect(reply.to.map(\.email) == [anna.email])
        let all = await ComposeModel.make(
            request: ComposeRequest(kind: .replyAll(id)), store: box.store, accounts: [anna, carl])
        #expect(all.to.map(\.email) == [anna.email])
        #expect(all.cc.map(\.email) == ["dora@example.org"])
    }

    @Test func replyUsesEveryReplyToAddress() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 4,
            body: try mail(
                from: address("bo@example.org"), to: [address(anna.email)],
                replyTo: [address("list@example.org"), address("bo@example.org")]))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(model.to.map(\.email) == ["list@example.org", "bo@example.org"])
    }

    @Test func replyAllLeavesOutTheOwnerAndRepeats() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 5,
            body: try mail(
                from: address("bo@example.org"),
                to: [address("ANNA@example.org"), address("carl@example.org"), address("bo@example.org")],
                cc: [address("carl@example.org"), address("dora@example.org"), address(anna.email)]))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .replyAll(id)), store: box.store, accounts: [anna])
        #expect(model.to.map(\.email) == ["bo@example.org", "carl@example.org"])
        #expect(model.cc.map(\.email) == ["dora@example.org"])
    }

    @Test func reopenedDraftKeepsLinksAndSpaces() throws {
        var body = AttributedString("Se  sidan")
        var link = AttributedString("här")
        link.link = URL(string: "https://example.org/a")
        body += link
        let html = try #require(RichText.html(body))
        let back = RichText.attributed(fromHTML: html)
        #expect(String(back.characters) == "Se  sidanhär")
        #expect(back.runs.compactMap(\.link) == [URL(string: "https://example.org/a")])
    }

    @Test func signatureFollowsTheChosenAccount() throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        var bo = try box.addAccount("bo@example.org")
        anna.signature = "Anna A"
        bo.signature = "Bo B"
        try box.store.save(anna)
        try box.store.save(bo)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna, bo])
        model.from = bo.id
        #expect(String(model.body.characters).contains("Bo B"))
        #expect(!String(model.body.characters).contains("Anna A"))
        model.body = AttributedString("Mitt eget")
        model.from = anna.id
        #expect(String(model.body.characters) == "Mitt eget")
    }

    @Test func aWebAddressInTheSignatureIsALink() throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.signature = "Anna A\nhttps://example.org/anna"
        try box.store.save(anna)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        #expect(model.body.runs.compactMap(\.link) == [URL(string: "https://example.org/anna")])
        #expect(RichText.html(model.body)?.contains("href=\"https://example.org/anna\"") == true)
    }

    @Test func theDefaultSignatureIsItsTextLinked() throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.signature = DefaultSignature.text
        try box.store.save(anna)
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        let linked = model.body.runs.filter { $0.link != nil }
        #expect(linked.map { String(model.body[$0.range].characters) } == ["Outwright for iOS"])
        #expect(!String(model.body.characters).contains("https://"))
        #expect(linked.compactMap(\.link) == [DefaultSignature.link])
    }

    @Test func titleSaysWhatIsWritten() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try received(box, anna, subject: "Hej", text: "Hej")
        let kinds: [(ComposeRequest.Kind, ComposeModel.Purpose)] = [
            (.new, .new), (.reply(id), .reply), (.replyAll(id), .reply), (.forward(id), .forward),
        ]
        for (kind, purpose) in kinds {
            let model = await ComposeModel.make(request: ComposeRequest(kind: kind), store: box.store, accounts: [anna])
            #expect(model.purpose == purpose)
        }
    }

    @Test func forwardedAttachmentsCountTowardsTheLimit() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let big = Attachment(
            filename: "big.bin", mimeType: "application/octet-stream", contentID: nil, isInline: false,
            data: Data(count: 80 << 10))
        let data = try MIMEWriter.write(
            OutgoingMessage(
                from: address("bo@example.org"), to: [address(anna.email)], cc: [], bcc: [], subject: "Stor",
                textBody: "x", htmlBody: nil, attachments: [big], inReplyTo: nil, references: [],
                date: Date(timeIntervalSince1970: 1_800_000_000), messageID: "big@example.org"),
            includeBcc: false)
        let id = try box.add(anna, uid: 6, body: data)
        let model = await ComposeModel.make(request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna])
        model.attachmentLimit = 100 << 10
        #expect(model.attachments.count == 1)
        let more = Attachment(
            filename: "more.bin", mimeType: "application/octet-stream", contentID: nil, isInline: false,
            data: Data(count: 24 << 10))
        #expect(!model.attach(more))
        model.attachments.append(more)
        model.to = [address("carl@example.org")]
        #expect(throws: ComposeError.tooLarge) { try model.send() }
    }

    @Test func quotedHeaderIsLocalised() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 7,
            body: try mail(from: address("bo@example.org"), to: [address(anna.email)], cc: [address("carl@example.org")]))
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna], locale: swedish)
        #expect(shownText(model).contains("Kopia: carl@example.org"))
    }

    /// A draft from another client whose Message-ID cannot be written is saved under a new one.
    @Test func aDraftWithAnUnwritableMessageIDIsSavedUnderANewOne() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let long = String(repeating: "x", count: 1_000) + "@example.org"
        let raw = Data(("From: anna@example.org\r\nTo: bo@example.org\r\nSubject: Utkast\r\nMessage-ID: <\(long)>\r\n"
            + "MIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nHej\r\n").utf8)
        let id = try box.add(anna, .drafts, uid: 3, subject: "Utkast", body: raw)
        let model = await ComposeModel.make(request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna])
        model.to = [Address(name: nil, email: "bo@example.org")]
        try model.send()
        let draft = try #require(try draftRows(box, anna).first)
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.messageID != nil)
        #expect(parsed.messageID != long)
    }

    /// A message the writer refuses is said to be unwritable, not too large.
    @Test func aMessageTheWriterRefusesIsNotCalledTooLarge() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.to = [Address(name: nil, email: String(repeating: "a", count: 250) + "@example.org")]
        #expect(throws: ComposeError.notWritable) { try model.send() }
    }

    // MARK: - Recipients, the quoted original, attachments

    @Test func duplicateRecipientIsSkipped() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.add([address("bo@example.org")], to: .to)
        model.add([address("BO@example.org"), address("carl@example.org"), address("carl@example.org")], to: .cc)
        #expect(model.to.map(\.email) == ["bo@example.org"])
        #expect(model.cc.map(\.email) == ["carl@example.org"])
        try model.send(typed: [.bcc: "bo@example.org, dora@example.org"])
        let draft = try #require(try draftRows(box, anna).first)
        let parsed = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        #expect(parsed.bcc.map(\.email) == ["dora@example.org"])
    }

    private func htmlMail(html: String, inline: [OutwrightMIME.Attachment] = []) throws -> Data {
        try MIMEWriter.write(
            OutgoingMessage(
                from: address("bo@example.org"), to: [address("anna@example.org")], cc: [], bcc: [], subject: "Bild",
                textBody: "Hej Anna", htmlBody: html, attachments: inline, inReplyTo: nil, references: [],
                date: Date(timeIntervalSince1970: 1_800_000_000), messageID: "html@example.org"),
            includeBcc: false)
    }

    @Test func forwardKeepsInlineParts() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let picture = Attachment(
            filename: "pic.png", mimeType: "image/png", contentID: "pic1@example.org", isInline: true,
            data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        let id = try box.add(
            anna, uid: 8, body: try htmlMail(html: "<p>Se <img src=\"cid:pic1@example.org\"></p>", inline: [picture]))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna])
        #expect(model.attachments.isEmpty, "an inline picture is no attachment chip")
        model.to = [address("carl@example.org")]
        try model.send()
        let draft = try #require(try draftRows(box, anna).first)
        let sent = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        let kept = try #require(sent.attachments.first { $0.contentID == "pic1@example.org" })
        #expect(kept.isInline)
        #expect(kept.data == picture.data)
        #expect(sent.htmlBody?.contains("cid:pic1@example.org") == true)
    }

    /// A forward's inline picture too large for the room left goes, with its picture in the quote, and
    /// is counted for the owner; the forward's files stay.
    @Test func anOversizedInlinePartIsLeftOut() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let file = Attachment(
            filename: "notes.bin", mimeType: "application/octet-stream", contentID: nil, isInline: false,
            data: Data(count: 60 << 10))
        let small = Attachment(
            filename: "small.png", mimeType: "image/png", contentID: "small@example.org", isInline: true,
            data: Data(count: 10 << 10))
        let big = Attachment(
            filename: "big.png", mimeType: "image/png", contentID: "big@example.org", isInline: true,
            data: Data(count: 60 << 10))
        let html = "<p>A <img src=\"cid:small@example.org\"> B <img src=\"cid:big@example.org\"></p>"
        let id = try box.add(anna, uid: 11, body: try htmlMail(html: html, inline: [file, small, big]))
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna],
            attachmentLimit: 100 << 10)
        #expect(model.attachments.map(\.filename) == ["notes.bin"])
        #expect(model.quoted?.inline.compactMap(\.contentID) == ["small@example.org"])
        #expect(model.leftOut.tooLarge == 1)
        #expect(model.attachmentBytes <= 100 << 10)
        model.to = [address("carl@example.org")]
        try model.send()
        let draft = try #require(try draftRows(box, anna).first)
        let sent = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        let html2 = try #require(sent.htmlBody)
        #expect(html2.contains("cid:small@example.org"))
        #expect(!html2.contains("cid:big@example.org"))
    }

    /// What didn't fit is said once: taking it empties it.
    @Test func whatWasLeftOutIsSaidOnce() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let big = Attachment(
            filename: "big.png", mimeType: "image/png", contentID: "big@example.org", isInline: true,
            data: Data(count: 60 << 10))
        let id = try box.add(anna, uid: 12, body: try htmlMail(html: "<img src=\"cid:big@example.org\">", inline: [big]))
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .forward(id)), store: box.store, accounts: [anna], attachmentLimit: 10 << 10)
        #expect(model.takeLeftOut().tooLarge == 1)
        #expect(model.takeLeftOut().isEmpty)
    }

    /// A pasted list, one address a line, is read as that many addresses.
    @Test func addressesOnLinesOfTheirOwnAreSplit() {
        let (found, rest) = RecipientParser.split("a@example.org\nb@example.org\r\nc@example.org\rnot one")
        #expect(found.map(\.email) == ["a@example.org", "b@example.org", "c@example.org"])
        #expect(rest == ["not one"])
    }

    @Test func replyCarriesTheOriginalHTMLAsCite() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let html = "<html><head><style>p{color:red}</style></head><body><p onclick=\"steal()\">Hej <b>Anna</b></p>"
            + "<script>alert(1)</script><a href=\"javascript:steal()\">x</a></body></html>"
        let id = try box.add(anna, uid: 9, body: try htmlMail(html: html))
        let model = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        #expect(!String(model.body.characters).contains("Hej Anna"), "the original is under the editor, not in it")
        #expect(model.quoted?.text.contains("Hej Anna") == true)
        model.body = AttributedString("Tack!")
        try model.send()
        let draft = try #require(try draftRows(box, anna).first)
        let sent = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        let sentHTML = try #require(sent.htmlBody)
        let cite = try #require(sentHTML.range(of: "<blockquote type=\"cite\">"))
        let own = try #require(sentHTML.range(of: "Tack!"))
        #expect(own.upperBound <= cite.lowerBound)
        #expect(sentHTML[cite.upperBound...].contains("<b>Anna</b>"))
        for unsafe in ["<script", "onclick", "javascript:", "<style"] {
            #expect(!sentHTML.lowercased().contains(unsafe))
        }
        #expect(sent.textBody?.contains("> Hej Anna") == true)
    }

    /// A reply kept as a draft opens again with the owner's text in the editor and the original under
    /// it, and is sent with the original quoted once.
    @Test func aDraftKeepsItsQuoteUnderTheEditor() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 10, body: try htmlMail(html: "<p>Hej <b>Anna</b></p>"))
        let reply = await ComposeModel.make(request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna])
        reply.body = AttributedString("Utkast")
        try reply.close()
        let draft = try #require(try draftRows(box, anna).first)
        let reopened = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(draft.id)), store: box.store, accounts: [anna])
        #expect(String(reopened.body.characters) == "Utkast")
        #expect(reopened.quoted?.text.contains("Hej Anna") == true)
        reopened.body = AttributedString("Utkast, klart")
        try reopened.send()
        let sent = try MIMEParser.parse(try #require(try box.store.body(draft.id)))
        let html = try #require(sent.htmlBody)
        #expect(html.components(separatedBy: "<blockquote type=\"cite\">").count == 2)
        #expect(html.contains("<b>Anna</b>"))
    }

    @Test func failedAttachmentsAreCountedTogether() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        model.attachmentLimit = 1_000
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, _ bytes: Int) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }
        var urls = [try file("big1.bin", 2_000), try file("big2.bin", 2_000), folder.appendingPathComponent("gone.bin")]
        for index in 0..<19 { urls.append(try file("small\(index).txt", 10)) }
        let failed = model.attachFiles(urls)
        #expect(failed.tooLarge == 2)
        #expect(failed.unreadable == 1)
        #expect(failed.pastTheLimit == 2)
        #expect(model.attachments.count == 17)
    }

    @Test func writingStartsAboveTheSignature() async throws {
        var box = try Mailbox()
        var anna = try box.addAccount("anna@example.org")
        anna.signature = "Anna Andersson"
        try box.store.save(anna)
        let original = try received(box, anna, subject: "Möte", text: "Ses i morgon.")
        let reply = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(original)), store: box.store, accounts: [anna])
        #expect(reply.cursorOnEntering == 0)
        let fresh = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        #expect(fresh.cursorOnEntering == 0)

        // Once the body is written in, the cursor is where the writer left it.
        reply.body = AttributedString("Gärna.") + reply.body
        #expect(reply.cursorOnEntering == nil)
        try reply.keep()
        #expect(reply.cursorOnEntering == nil, "kept as a draft in the background, still written in")

        // A draft opened again is the writer's text: the editor places the cursor.
        fresh.to = [Address(name: nil, email: "bo@example.org")]
        fresh.body = AttributedString("Hej Bo")
        try fresh.close()
        let draft = try #require(try draftRows(box, anna).first)
        let reopened = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(draft.id)), store: box.store, accounts: [anna])
        #expect(reopened.cursorOnEntering == nil)
    }
}
