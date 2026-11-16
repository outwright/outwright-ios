// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A protection for tests: its submissions, headers and draft rewrite are what the test sets.
struct FakeProtection: MailProtection {
    let id = ProtectionID(raw: "test")
    var submissions: [Submission] = []
    var ownCopy = Data("OWN".utf8)
    var failure: ProtectionFailure?
    var header: (name: String, value: String)? = (name: "X-Hook", value: "yes")
    var draft: Data?

    func headers(for account: Account) async -> [(name: String, value: String)] {
        header.map { [$0] } ?? []
    }

    func protect(_ message: OutgoingMessage, requirement: ProtectionRequirement, account: Account)
        async throws(ProtectionFailure) -> ProtectedSend {
        if let failure { throw failure }
        return ProtectedSend(submissions: submissions, ownCopy: ownCopy)
    }

    func protectDraft(_ raw: Data, account: Account) async -> Data? { draft }

    func learn(from message: MIMEMessage, facts: ProtectionFacts?, folder: FolderKind, account: Account) async {}
}

private let recipients = ["bo@example.org", "cy@example.org", "dee@example.org"]

private func requirement(plain: Bool = false, _ list: [String] = recipients) -> ProtectionRequirement {
    ProtectionRequirement(protection: ProtectionID(raw: "test"), recipients: list.sorted(), plainChosen: plain)
}

private func syncer(_ h: Harness, _ protections: [any MailProtection]) -> AccountSyncer {
    AccountSyncer(account: h.account, store: h.store, secrets: h.secrets, now: { fixedNow }, protections: protections)
}

@Suite struct ProtectedSendTests {
    func queued(_ h: Harness, _ requirement: ProtectionRequirement?) throws -> MessageID {
        let id = try localDraft(h, uid: 0, data: try draftData())
        try h.store.setProtection(requirement, for: id)
        try h.store.apply(.send(draftID: id))
        return id
    }

    @Test func queuedProtectedDraftWithoutHookIsRefused() async throws {
        try await withHarness { h in
            let s = syncer(h, [])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .protectionUnavailable)
            #expect(await h.smtp.received.isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func plainChosenSendsPlain() async throws {
        try await withHarness { h in
            let s = syncer(h, [])
            try await s.syncFolders()
            _ = try queued(h, requirement(plain: true))
            try await s.runActions()
            let sent = try #require(await h.smtp.received.first)
            #expect(String(decoding: sent.data, as: UTF8.self).contains("See you at noon"))
            #expect(await h.smtp.received.count == 1)
        }
    }

    @Test func plainChosenForOtherRecipientsIsRefused() async throws {
        try await withHarness { h in
            let s = syncer(h, [])
            try await s.syncFolders()
            let id = try queued(h, requirement(plain: true, ["bo@example.org"]))
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .protectionUnavailable)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    @Test func hookSubmissionsAllGo() async throws {
        let hook = FakeProtection(submissions: [
            Submission(wire: Data("ONE".utf8), recipients: ["bo@example.org"]),
            Submission(wire: Data("TWO".utf8), recipients: ["cy@example.org", "dee@example.org"]),
        ])
        try await withHarness(await standardServer()) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try await s.runActions()
            let got = await h.smtp.received
            #expect(got.count == 2)
            #expect(got.map { Set($0.to) } == [["bo@example.org"], ["cy@example.org", "dee@example.org"]])
            let copy = try #require(await h.imap.messages(in: "Sent").first)
            #expect(String(decoding: copy.data, as: UTF8.self) == "OWN")
            #expect(try h.store.message(id) != nil)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func retryAfterPartialSendsOnlyTheRest() async throws {
        let hook = FakeProtection(submissions: [
            Submission(wire: Data("ONE".utf8), recipients: ["bo@example.org"]),
            Submission(wire: Data("TWO".utf8), recipients: ["cy@example.org"]),
        ])
        let smtp = FakeSMTPServer()
        await smtp.refuseRecipientOnce("cy@example.org", code: 450)
        try await withHarness(smtp: smtp) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            _ = try queued(h, requirement(["bo@example.org", "cy@example.org"]))
            await #expect(throws: SyncError.self) { try await s.runActions() }
            #expect(await h.smtp.received.count == 1)
            try await s.runActions()
            let got = await h.smtp.received
            #expect(got.map { Set($0.to) } == [["bo@example.org"], ["cy@example.org"]])
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func aRefusalAfterPartialSendsDoesNotResendToTheFirst() async throws {
        let hook = FakeProtection(submissions: [
            Submission(wire: Data("ONE".utf8), recipients: ["bo@example.org"]),
            Submission(wire: Data("TWO".utf8), recipients: ["cy@example.org"]),
        ])
        let smtp = FakeSMTPServer(rejectRecipient: "cy@example.org", rejectCode: 550)
        try await withHarness(smtp: smtp) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try queued(h, requirement(["bo@example.org", "cy@example.org"]))
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .recipientRefused)
            #expect(await h.smtp.received.count == 1)
            // Cy is accepted from now on; the owner sends again.
            await h.smtp.acceptAllRecipients()
            try h.store.apply(.send(draftID: id))
            try await s.runActions()
            #expect(await h.smtp.received.map { Set($0.to) } == [["bo@example.org"], ["cy@example.org"]])
        }
    }

    @Test func aRetryWithTheSubmissionsInAnotherOrderSendsEachAddressOnce() async throws {
        let one = Submission(wire: Data("ONE".utf8), recipients: ["bo@example.org"])
        let two = Submission(wire: Data("TWO".utf8), recipients: ["cy@example.org"])
        let smtp = FakeSMTPServer()
        await smtp.refuseRecipientOnce("cy@example.org", code: 450)
        try await withHarness(smtp: smtp) { h in
            let s = syncer(h, [FakeProtection(submissions: [one, two])])
            try await s.syncFolders()
            _ = try queued(h, requirement(["bo@example.org", "cy@example.org"]))
            await #expect(throws: SyncError.self) { try await s.runActions() }
            let reversed = syncer(h, [FakeProtection(submissions: [two, one])])
            try await reversed.runActions()
            #expect(await h.smtp.received.map { Set($0.to) } == [["bo@example.org"], ["cy@example.org"]])
        }
    }

    @Test func aHookWithNothingToSendRefuses() async throws {
        try await withHarness { h in
            let s = syncer(h, [FakeProtection(submissions: [])])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .protectionUnavailable)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    @Test func aSubmissionWithoutRecipientsIsNotSettledAsSent() async throws {
        let hook = FakeProtection(submissions: [Submission(wire: Data("ONE".utf8), recipients: [])])
        try await withHarness { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .invalidRecipient)
            #expect(try h.store.message(id)?.folderID == (try h.folder(.drafts)).id)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    @Test func aDraftWithoutRecipientsIsNotSettledAsSent() async throws {
        let message = OutgoingMessage(
            from: Address(name: nil, email: "jk@example.org"), to: [], cc: [], bcc: [], subject: "Plans",
            textBody: "Hi", htmlBody: nil, attachments: [], inReplyTo: nil, references: [], date: fixedNow,
            messageID: "draft1@example.org")
        let data = try MIMEWriter.write(message, includeBcc: true)
        try await withHarness { h in
            let s = syncer(h, [])
            try await s.syncFolders()
            let id = try localDraft(h, uid: 0, data: data)
            try h.store.apply(.send(draftID: id))
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .invalidRecipient)
            #expect(try h.store.message(id)?.folderID == (try h.folder(.drafts)).id)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    @Test func keyMissingRefuses() async throws {
        var hook = FakeProtection()
        hook.failure = .keyMissing(["cy@example.org"])
        try await withHarness { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .protectionKeyMissing)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    @Test func everyMailCarriesHookHeaders() async throws {
        try await withHarness { h in
            let s = syncer(h, [FakeProtection()])
            try await s.syncFolders()
            _ = try queued(h, nil)
            try await s.runActions()
            let sent = try #require(await h.smtp.received.first)
            #expect(String(decoding: sent.data, as: UTF8.self).contains("\r\nX-Hook: yes"))
        }
    }

    // MARK: - Signed, not encrypted

    private func signed() -> ProtectionRequirement {
        ProtectionRequirement(protection: ProtectionID(raw: "test"), recipients: [], plainChosen: false, kind: .sign)
    }

    /// A signed message goes through its protection whoever it is to: signing decides nothing per recipient.
    @Test func signedDraftGoesThroughTheProtection() async throws {
        let hook = FakeProtection(submissions: [Submission(wire: Data("SIGNED".utf8), recipients: recipients)])
        try await withHarness(await standardServer()) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            _ = try queued(h, signed())
            try await s.runActions()
            let got = await h.smtp.received
            #expect(got.count == 1)
            #expect(got.first.map { String(decoding: $0.data, as: UTF8.self).hasPrefix("SIGNED") } == true)
        }
    }

    /// Without the protection in the build a signed message goes as written: a signature hides nothing.
    @Test func signedDraftWithoutTheProtectionGoesAsWritten() async throws {
        try await withHarness { h in
            let s = syncer(h, [])
            try await s.syncFolders()
            _ = try queued(h, signed())
            try await s.runActions()
            let sent = try #require(await h.smtp.received.first)
            #expect(String(decoding: sent.data, as: UTF8.self).contains("See you at noon"))
        }
    }

    /// Plain chosen for some recipients and signed: other recipients are refused, as for plain.
    @Test func signedPlainChoiceForOtherRecipientsIsRefused() async throws {
        let hook = FakeProtection(submissions: [Submission(wire: Data("SIGNED".utf8), recipients: recipients)])
        try await withHarness { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let other = ProtectionRequirement(
                protection: ProtectionID(raw: "test"), recipients: ["bo@example.org"], plainChosen: true, kind: .sign)
            let id = try queued(h, other)
            try? await s.runActions()
            #expect(try h.store.message(id)?.notSent == .protectionUnavailable)
            #expect(await h.smtp.received.isEmpty)
        }
    }

    /// A signed draft is kept on the server as written, not hidden: it goes out readable anyway.
    @Test func signedDraftIsKeptAsWritten() async throws {
        var hook = FakeProtection()
        hook.draft = Data("X".utf8)
        let server = await standardServer()
        try await withHarness(server) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.setProtection(signed(), for: id)
            try h.store.apply(.saveDraft(id))
            try await s.runActions()
            let saved = try #require(await server.messages(in: "Drafts").first)
            #expect(String(decoding: saved.data, as: UTF8.self).contains("See you at noon"))
        }
    }

    @Test func protectedDraftSavedEncrypted() async throws {
        var hook = FakeProtection()
        hook.draft = Data("X".utf8)
        let server = await standardServer()
        try await withHarness(server) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let data = try draftData()
            let id = try localDraft(h, uid: 0, data: data)
            try h.store.setProtection(requirement(), for: id)
            try h.store.apply(.saveDraft(id))
            try await s.runActions()
            let saved = try #require(await server.messages(in: "Drafts").first)
            #expect(saved.data == Data("X".utf8))
            #expect(try h.store.body(id) == data)
        }
    }

    /// A draft that asks for protection never reaches the server's Drafts in the clear: when the
    /// protection cannot make it (or is not in the build), it stays here and is tried again.
    @Test func protectedDraftTheHookCannotMakeStaysLocal() async throws {
        for protections in [[FakeProtection()], []] as [[any MailProtection]] {
            let server = await standardServer()
            try await withHarness(server) { h in
                let s = syncer(h, protections)
                try await s.syncFolders()
                let data = try draftData()
                let id = try localDraft(h, uid: 0, data: data)
                try h.store.setProtection(requirement(), for: id)
                try h.store.apply(.saveDraft(id))
                try? await s.runActions()
                #expect(await server.messages(in: "Drafts").isEmpty)
                #expect(try h.store.body(id) == data)
                #expect(try h.store.pendingActions().count == 1)
            }
        }
    }

    /// Saves the hook cannot protect never hold back a send queued after them: the send goes out
    /// in the first run and nothing is given up.
    @Test func unprotectableSavesDoNotHoldBackTheSend() async throws {
        let hook = FakeProtection(submissions: [
            Submission(wire: Data("ONE".utf8), recipients: recipients),
        ])
        try await withHarness(await standardServer()) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.setProtection(requirement(), for: id)
            try h.store.apply(.saveDraft(id))
            try h.store.apply(.saveDraft(id))
            try h.store.apply(.send(draftID: id))
            try await s.runActions()
            #expect(await h.smtp.received.count == 1)
            #expect(await h.imap.messages(in: "Drafts").isEmpty)
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    /// Bytes that are `multipart/encrypted` at the top, as a protection writes them.
    static let encryptedShape = Data(
        ("From: jk@example.org\r\nSubject: ...\r\nMessage-ID: <draft1@example.org>\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"e\"\r\n"
            + "\r\n--e--\r\n").utf8)

    /// The owner's copy kept in Sent is protected: the row is marked, so the server's outer headers
    /// never overwrite the real subject.
    @Test func protectedOwnCopyMarksTheSentRow() async throws {
        var hook = FakeProtection(submissions: [Submission(wire: Data("ONE".utf8), recipients: recipients)])
        hook.ownCopy = Self.encryptedShape
        try await withHarness(await standardServer()) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try queued(h, requirement())
            try await s.runActions()
            var row = try #require(try h.store.message(id))
            #expect(row.isProtected)
            row.subject = "..."
            row.isProtected = false
            _ = try h.store.upsert([row])
            #expect(try h.store.message(id)?.subject == "Plans")
        }
    }

    /// A draft kept on the server protected marks its row, so the server's outer headers never
    /// overwrite the real subject.
    @Test func protectedDraftOnTheServerMarksItsRow() async throws {
        var hook = FakeProtection()
        hook.draft = Self.encryptedShape
        try await withHarness(await standardServer()) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.setProtection(requirement(), for: id)
            try h.store.apply(.saveDraft(id))
            try await s.runActions()
            var row = try #require(try h.store.message(id))
            #expect(row.isProtected)
            row.subject = "..."
            row.isProtected = false
            _ = try h.store.upsert([row])
            #expect(try h.store.message(id)?.subject == "Plans")
        }
    }

    /// A save the protection can't make yet waits, run after run, without being given up and without
    /// an error: it is done when it can be made, or a later save, send or delete takes over.
    @Test func anUnprotectableSaveWaitsQuietly() async throws {
        var hook = FakeProtection()
        let server = await standardServer()
        try await withHarness(server) { h in
            let s = syncer(h, [hook])
            try await s.syncFolders()
            let id = try localDraft(h, uid: 0, data: try draftData())
            try h.store.setProtection(requirement(), for: id)
            try h.store.apply(.saveDraft(id))
            for _ in 0..<(ActionRunner.maxAttempts + 2) {
                try await s.runActions()
            }
            #expect(try h.store.pendingActions().count == 1)
            #expect(await server.messages(in: "Drafts").isEmpty)
            hook.draft = Data("X".utf8)
            try await syncer(h, [hook]).runActions()
            #expect(try h.store.pendingActions().isEmpty)
            #expect(await server.messages(in: "Drafts").count == 1)
        }
    }
}
