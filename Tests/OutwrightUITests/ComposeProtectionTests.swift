// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import SwiftUI
import Testing

@testable import OutwrightUI

@MainActor private final class FakeProtectionUI: ProtectionUI {
    let protection = ProtectionID(raw: "fake")
    var answer = ComposeProtection(lockOn: true, mustAsk: true, recipients: [:])
    private(set) var asked: [[String]] = []
    /// When set, the answer follows the recipients: these have keys, the rest do not.
    var haveKeys: Set<String>?
    /// How long an answer takes.
    var delay: Duration = .zero
    /// While closed, an answer waits until `open()`.
    var isGated = false
    /// Run as each question is asked (with how many have been), before it is answered.
    var onAsk: ((Int) -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    func open() {
        isGated = false
        waiter?.resume()
        waiter = nil
    }

    func compose(
        recipients: [Address], account: Account, original: ProtectionFacts?, ownerLock: Bool?, ownerSign: Bool?
    ) async -> ComposeProtection
    {
        asked.append(recipients.map(\.email))
        onAsk?(asked.count)
        var result = answer
        if let haveKeys {
            result.recipients = Dictionary(
                uniqueKeysWithValues: recipients.map {
                    ($0.email.lowercased(), haveKeys.contains($0.email.lowercased()) ? RecipientKey.has : .none)
                })
        }
        if isGated { await withCheckedContinuation { waiter = $0 } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
    func keyImporter(for address: String) -> AnyView { AnyView(EmptyView()) }
    func readingMarks(_ facts: ProtectionFacts, sender: Address) -> AnyView { AnyView(EmptyView()) }
    func personSection(for address: String) -> AnyView { AnyView(EmptyView()) }
}

@MainActor @Suite struct ComposeProtectionTests {
    private func make(
        _ ui: (any ProtectionUI)?, protection: ComposeProtection?, to: [String] = ["bo@example.org", "Cy@example.org"]
    ) throws -> (ComposeModel, Mailbox) {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(
            request: ComposeRequest(kind: .new), store: box.store, accounts: [anna], protectionUI: ui)
        model.to = to.map { Address(name: nil, email: $0) }
        model.protection = protection
        return (model, box)
    }

    private func requirement(_ model: ComposeModel, _ box: Mailbox) throws -> ProtectionRequirement? {
        try box.store.protection(of: try #require(model.draftID))
    }

    private let keys = ["bo@example.org": RecipientKey.has, "cy@example.org": .changed]

    @Test func lockOnStoresRequirement() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: keys))
        try model.send()
        #expect(
            try requirement(model, box)
                == ProtectionRequirement(
                    protection: ProtectionID(raw: "fake"), recipients: ["bo@example.org", "cy@example.org"],
                    plainChosen: false))
    }

    @Test func keylessRecipientWithMustAskThrows() throws {
        var recipients = keys
        recipients["cy@example.org"] = RecipientKey.none
        let (model, _) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: recipients))
        #expect(throws: ComposeError.needsProtectionChoice(missing: [Address(name: nil, email: "Cy@example.org")])) {
            try model.send()
        }
        #expect(!model.isFinished)
        #expect(model.draftID == nil)
    }

    @Test func sendPlainStoresPlainChosen() throws {
        var recipients = keys
        recipients["cy@example.org"] = RecipientKey.looking
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: recipients))
        try model.send(choice: .sendPlain)
        let stored = try #require(try requirement(model, box))
        #expect(stored.plainChosen)
        #expect(stored.recipients == ["bo@example.org", "cy@example.org"])
    }

    @Test func removeKeylessDropsThemAndEncrypts() throws {
        var recipients = keys
        recipients["cy@example.org"] = RecipientKey.none
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: recipients))
        try model.send(choice: .removeKeyless)
        #expect(model.to.map(\.email) == ["bo@example.org"])
        let stored = try #require(try requirement(model, box))
        #expect(stored.recipients == ["bo@example.org"])
        #expect(!stored.plainChosen)
    }

    @Test func removingEveryoneSendsNothing() throws {
        let none = ["bo@example.org": RecipientKey.none]
        let (model, _) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: none),
            to: ["bo@example.org"])
        #expect(throws: ComposeError.noRecipients) { try model.send(choice: .removeKeyless) }
        #expect(model.to.map(\.email) == ["bo@example.org"])
    }

    @Test func lockOffStoresNothing() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:]))
        try model.send()
        #expect(try requirement(model, box) == nil)
    }

    // MARK: - Signed, not encrypted

    private func signed(plain: Bool = false, _ recipients: [String] = []) -> ProtectionRequirement {
        ProtectionRequirement(
            protection: ProtectionID(raw: "fake"), recipients: recipients, plainChosen: plain, kind: .sign)
    }

    @Test func lockOffWithSignStoresSigned() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], signOn: true))
        try model.send()
        #expect(try requirement(model, box) == signed())
    }

    /// Plain chosen for keyless recipients goes signed, still only to those very recipients.
    @Test func plainChosenWithSignIsSigned() throws {
        var recipients = keys
        recipients["cy@example.org"] = RecipientKey.none
        let (model, box) = try make(
            FakeProtectionUI(),
            protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: recipients, signOn: true))
        try model.send(choice: .sendPlain)
        #expect(try requirement(model, box) == signed(plain: true, ["bo@example.org", "cy@example.org"]))
    }

    /// A lock that is only a wish, with someone keyless: the message goes signed instead.
    @Test func wishedLockWithAKeylessRecipientSigns() throws {
        var recipients = keys
        recipients["cy@example.org"] = RecipientKey.none
        let (model, box) = try make(
            FakeProtectionUI(),
            protection: ComposeProtection(lockOn: true, mustAsk: false, recipients: recipients, signOn: true))
        try model.send()
        #expect(try requirement(model, box) == signed())
    }

    /// An account that can't protect can't sign either: the message goes as it is.
    @Test func accountThatCannotProtectDoesNotSign() throws {
        let (model, box) = try make(
            FakeProtectionUI(),
            protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], canProtect: false, signOn: true))
        try model.send()
        #expect(try requirement(model, box) == nil)
    }

    @Test func toggleSignIsTheOwnersChoice() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], signOn: true))
        model.toggleSign()
        #expect(model.protection?.signOn == false)
        try model.send()
        #expect(try requirement(model, box) == nil)
    }

    @Test func calendarReplyNeverProtected() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let raw = Data(
            """
            From: anna@example.org\r
            To: bo@example.org\r
            Subject: Accepted\r
            Message-ID: <c@example.org>\r
            MIME-Version: 1.0\r
            Content-Type: multipart/alternative; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain\r
            \r
            Accepted\r
            --b\r
            Content-Type: text/calendar; method=REPLY\r
            \r
            BEGIN:VCALENDAR\r
            METHOD:REPLY\r
            END:VCALENDAR\r
            --b--\r

            """.utf8)
        let id = try box.add(
            anna, .drafts, uid: 0, from: "anna@example.org", subject: "Accepted", body: raw, to: ["bo@example.org"])
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna],
            protectionUI: FakeProtectionUI())
        model.protection = ComposeProtection(
            lockOn: true, mustAsk: true, recipients: ["bo@example.org": RecipientKey.none])
        try model.send()
        #expect(try box.store.protection(of: try #require(model.draftID)) == nil)
    }

    @Test func noProtectionUIBehavesAsToday() throws {
        let (model, box) = try make(nil, protection: nil)
        model.protection = ComposeProtection(
            lockOn: true, mustAsk: true, recipients: ["bo@example.org": RecipientKey.none])
        try model.send()
        #expect(try requirement(model, box) == nil)
    }

    @Test func toggleLockFlipsItAndNoteOwnerChoice() throws {
        let (model, _) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:]))
        model.toggleLock()
        #expect(model.protection?.lockOn == true)
        #expect(model.protection?.mustAsk == true)
        model.toggleLock()
        #expect(model.protection?.lockOn == false)
    }

    @Test func refreshAsksAgainWithTheRecipients() async throws {
        let ui = FakeProtectionUI()
        ui.answer = ComposeProtection(lockOn: true, mustAsk: false, recipients: keys)
        let (model, _) = try make(ui, protection: nil)
        await model.refreshProtection()
        #expect(ui.asked == [["bo@example.org", "Cy@example.org"]])
        #expect(model.protection == ui.answer)
    }

    @Test func keptLockedDraftCarriesARequirement() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: keys))
        model.toggleLock()
        model.toggleLock()
        try model.close()
        #expect(try requirement(model, box)?.plainChosen == false)
    }

    @Test func keepingWhileTheAnswerIsUnknownLeavesTheStoredRequirement() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: keys))
        try model.keep()
        let stored = try requirement(model, box)
        #expect(stored != nil)
        model.protection = nil
        model.subject = "changed"
        try model.keep()
        #expect(try requirement(model, box) == stored)
    }

    @Test func reopenedLockedDraftAsksAboutKeylessRecipients() async throws {
        let ui = FakeProtectionUI()
        ui.haveKeys = ["bo@example.org"]
        ui.answer.mustAsk = false
        let (first, box) = try make(
            ui, protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: keys))
        try first.close()
        let id = try #require(first.draftID)
        let again = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: box.accounts, protectionUI: ui)
        await again.refreshProtection()
        #expect(throws: ComposeError.needsProtectionChoice(missing: [Address(name: nil, email: "Cy@example.org")])) {
            try again.send()
        }
    }

    /// A draft kept to be signed only comes back signed, not locked: Send doesn't ask about keys.
    @Test func reopenedSignedDraftIsNotLocked() async throws {
        let ui = FakeProtectionUI()
        ui.haveKeys = ["bo@example.org"]
        ui.answer = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], signOn: true)
        let (first, box) = try make(
            ui, protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: keys, signOn: true))
        try first.close()
        let id = try #require(first.draftID)
        #expect(try box.store.protection(of: id)?.kind == .sign)
        let again = await ComposeModel.make(
            request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: box.accounts, protectionUI: ui)
        #expect(again.ownerLock == nil)
        await again.refreshProtection()
        try again.send()
        #expect(try box.store.protection(of: id)?.kind == .sign)
    }

    /// Encrypted stays encrypted with signing on: the signature is inside.
    @Test func encryptedWithSignIsStillEncrypt() throws {
        let (model, box) = try make(
            FakeProtectionUI(), protection: ComposeProtection(lockOn: true, mustAsk: false, recipients: keys, signOn: true))
        try model.send()
        #expect(try requirement(model, box)?.kind == .encrypt)
    }

    /// No answer from the protection: the owner is asked, and plain goes signed while signing is on.
    @Test func unansweredSendPlainKeepsTheSignature() async throws {
        let ui = FakeProtectionUI()
        let (model, box) = try make(
            ui, protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: keys, signOn: true))
        // Every answer comes for recipients that changed meanwhile, so none is taken.
        ui.onAsk = { count in model.cc.append(Address(name: nil, email: "c\(count)@example.org")) }
        try await model.send(afterLookupOf: [:], choice: .sendPlain)
        #expect(try requirement(model, box)?.kind == .sign)
    }

    @Test func aLateAnswerIsDropped() async throws {
        let ui = FakeProtectionUI()
        ui.delay = .milliseconds(150)
        ui.answer = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:])
        let (model, _) = try make(ui, protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:]))
        let late = Task { await model.refreshProtection() }
        try await Task.sleep(for: .milliseconds(30))
        model.toggleLock()
        _ = await late.value
        #expect(model.protection?.lockOn == true)
    }

    @Test func typedRecipientsAreLookedUpBeforeSending() async throws {
        let ui = FakeProtectionUI()
        ui.haveKeys = ["bo@example.org", "dee@example.org"]
        let (model, box) = try make(
            ui, protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: [:]), to: ["bo@example.org"])
        try await model.send(afterLookupOf: [.to: "dee@example.org"], choice: .removeKeyless)
        let stored = try #require(try requirement(model, box))
        #expect(stored.recipients == ["bo@example.org", "dee@example.org"])
        #expect(model.to.map(\.email) == ["bo@example.org", "dee@example.org"])
    }

    @Test func failedSendAfterLookupAddsTypedRecipientsOnlyOnce() async throws {
        let ui = FakeProtectionUI()
        ui.haveKeys = ["bo@example.org", "dee@example.org"]
        let (model, box) = try make(
            ui, protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: [:]), to: ["bo@example.org"])
        try box.store.refuseQueuedActions(true)
        await #expect(throws: ComposeError.store) {
            try await model.send(afterLookupOf: [.to: "dee@example.org"])
        }
        #expect(model.to.map(\.email) == ["bo@example.org"])
        try box.store.refuseQueuedActions(false)
        try await model.send(afterLookupOf: [.to: "dee@example.org"])
        #expect(model.to.map(\.email) == ["bo@example.org", "dee@example.org"])
    }

    @Test func overlappingSendsRunOnce() async throws {
        let ui = FakeProtectionUI()
        ui.isGated = true
        ui.haveKeys = ["bo@example.org", "cy@example.org"]
        let (model, _) = try make(ui, protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: [:]))
        let first = Task { try await model.send(afterLookupOf: [:]) }
        while !model.isSending { await Task.yield() }
        await #expect(throws: ComposeError.alreadySending) { try await model.send(afterLookupOf: [:]) }
        ui.open()
        try await first.value
        #expect(ui.asked.count == 1)
        #expect(!model.isSending)
        #expect(model.isFinished)
    }

    // MARK: - Protected originals, drafts and partial sends

    private static let decrypted = ProtectionFacts(decryption: .decrypted, signature: .none, resentBy: nil)

    private func original(_ box: Mailbox, _ account: Account, protected: Bool = false) throws -> MessageID {
        let id = try box.add(account, .inbox, uid: 7, from: "bo@example.org", subject: "Plans")
        if protected {
            var row = try #require(try box.store.message(id))
            row.isProtected = true
            _ = try box.store.upsert([row])
        }
        return id
    }

    private func plainMessage(from: String = "bo@example.org") -> MIMEMessage {
        var message = MIMEMessage()
        message.from = [Address(name: nil, email: from)]
        message.to = [Address(name: nil, email: "anna@example.org")]
        message.subject = "Plans"
        message.textBody = "Secret plans."
        message.messageID = "orig@example.org"
        return message
    }

    /// A reply kept before the protection has answered, to a message that was decrypted, already asks to
    /// be protected: it never reaches the server's Drafts in the clear.
    @Test func replyToDecryptedMailKeptBeforeTheAnswerIsProtected() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try original(box, anna)
        let model = ComposeModel(
            request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna],
            protectionUI: FakeProtectionUI(), opened: OpenedMessage(message: plainMessage(), facts: Self.decrypted))
        #expect(model.protection == nil)
        model.body += AttributedString("Agreed.")
        try model.keep()
        let stored = try #require(try requirement(model, box))
        #expect(!stored.plainChosen)
        #expect(stored.recipients == ["bo@example.org"])
    }

    /// A reply to a protected message whose body is not on the phone is treated as one to a decrypted
    /// message: kept protected, and the protection is told the original was protected.
    @Test func replyToProtectedRowWithoutBodyIsProtected() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try original(box, anna, protected: true)
        let model = await ComposeModel.make(
            request: ComposeRequest(kind: .reply(id)), store: box.store, accounts: [anna],
            protectionUI: FakeProtectionUI())
        model.body += AttributedString("Agreed.")
        try model.keep()
        #expect(try requirement(model, box)?.plainChosen == false)
        #expect(model.original.map { $0.decryption != .none } == true)
    }

    /// A draft that the server held encrypted and that was opened decrypted is locked again.
    @Test func draftOpenedDecryptedIsLocked() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, .drafts, uid: 3, from: "anna@example.org", subject: "Plans", to: ["bo@example.org"])
        var parsed = plainMessage(from: "anna@example.org")
        parsed.to = [Address(name: nil, email: "bo@example.org")]
        let model = ComposeModel(
            request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna],
            protectionUI: FakeProtectionUI(), opened: OpenedMessage(message: parsed, facts: Self.decrypted))
        #expect(model.ownerLock == true)
        model.subject = "Changed"
        try model.keep()
        #expect(try requirement(model, box)?.plainChosen == false)
    }

    /// When the protection cannot protect from the account (it has no key of its own yet) and the
    /// message must ask, Send stops with a reason of its own; the owner may send it unprotected.
    @Test func protectionUnavailableStopsSendAndOffersPlain() throws {
        let (model, box) = try make(
            FakeProtectionUI(),
            protection: ComposeProtection(lockOn: false, mustAsk: true, recipients: keys, canProtect: false))
        #expect(throws: ComposeError.protectionUnavailable) { try model.send() }
        #expect(!model.isFinished)
        try model.send(choice: .sendPlain)
        let stored = try #require(try requirement(model, box))
        #expect(stored.plainChosen)
    }

    /// Without the question, a protection that cannot protect asks for nothing: the message goes as it is.
    @Test func protectionUnavailableWithoutMustAskSendsPlain() throws {
        let (model, box) = try make(
            FakeProtectionUI(),
            protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: keys, canProtect: false))
        try model.send()
        #expect(try requirement(model, box) == nil)
    }

    /// An answer dropped because the recipients changed while it was asked is asked for again, so
    /// Send never goes by the answer for the recipients before.
    @Test func sendAsksAgainWhenTheAnswerWasForOtherRecipients() async throws {
        let ui = FakeProtectionUI()
        ui.answer = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:])
        let (model, box) = try make(ui, protection: ComposeProtection(lockOn: true, mustAsk: true, recipients: [:]))
        ui.onAsk = { count in if count == 1 { model.cc.append(Address(name: nil, email: "dee@example.org")) } }
        try await model.send(afterLookupOf: [:])
        #expect(ui.asked.count == 2)
        #expect(model.isFinished)
        #expect(try requirement(model, box) == nil)
    }

    /// Recipients that keep changing while the protection is asked: after a few tries the answer is
    /// unknown, and Send asks the owner.
    @Test func sendWithNoAnswerForTheRecipientsAsks() async throws {
        let ui = FakeProtectionUI()
        ui.answer = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:])
        let (model, _) = try make(ui, protection: ComposeProtection(lockOn: false, mustAsk: false, recipients: [:]))
        ui.onAsk = { count in model.cc.append(Address(name: nil, email: "p\(count)@example.org")) }
        await #expect(throws: ComposeError.self) { try await model.send(afterLookupOf: [:]) }
        #expect(ui.asked.count == 3)
        #expect(!model.isFinished)
        #expect(model.protection?.mustAsk == true)
    }

    /// After a send that reached some recipients and was then refused, a changed draft goes to everyone
    /// again; an unchanged one only to the rest.
    @Test func editingADraftAfterAPartialSendResetsWhoHasIt() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        first.to = [Address(name: nil, email: "bo@example.org"), Address(name: nil, email: "cy@example.org")]
        first.subject = "Plans"
        try first.close()
        let id = try #require(first.draftID)
        try box.store.addSubmitted(["bo@example.org"], to: id)

        let unchanged = ComposeModel(request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna])
        try unchanged.send()
        #expect(try box.store.submittedTo(of: id) == ["bo@example.org"])

        let edited = ComposeModel(request: ComposeRequest(kind: .draft(id)), store: box.store, accounts: [anna])
        edited.subject = "Plans, corrected"
        try edited.send()
        #expect(try box.store.submittedTo(of: id).isEmpty)
    }
}

/// What the line under the subject says the lock does: what Send then does.
@MainActor
@Suite struct ComposeProtectionNoteTests {
    private let anna = Address(name: nil, email: "Anna@example.org")
    private let bo = Address(name: nil, email: "bo@example.org")

    private func note(
        _ state: ComposeProtection?, _ recipients: [Address], fromStart: Bool = false
    ) -> ProtectionNote? {
        ComposeModel.note(state, recipients: recipients, protectedFromStart: fromStart)
    }

    @Test func lockOnWithEveryRecipientKeyedIsEncrypted() {
        let state = ComposeProtection(
            lockOn: true, mustAsk: false, recipients: ["anna@example.org": .has, "bo@example.org": .changed])
        #expect(note(state, [anna, bo]) == .encrypted)
    }

    /// Send asks about a recipient without a key when the lock must ask.
    @Test func keylessRecipientWhenAskingSaysNotEveryone() {
        let state = ComposeProtection(
            lockOn: true, mustAsk: true, recipients: ["anna@example.org": .has, "bo@example.org": .none])
        #expect(note(state, [anna, bo]) == .notEveryone)
    }

    /// Without the question the lock is only a wish: Send sends it as it is.
    @Test func keylessRecipientWithoutAskingIsNotEncrypted() {
        let state = ComposeProtection(
            lockOn: true, mustAsk: false, recipients: ["anna@example.org": .has, "bo@example.org": .none])
        #expect(note(state, [anna, bo]) == .notEncrypted)
    }

    /// A key being looked up, or a recipient not yet asked about (just added, or still typed), is
    /// not known yet: nothing is promised.
    @Test func keyNotYetKnownIsChecking() {
        let state = ComposeProtection(lockOn: true, mustAsk: false, recipients: ["anna@example.org": .looking])
        #expect(note(state, [anna]) == .checking)
        let answered = ComposeProtection(lockOn: true, mustAsk: false, recipients: ["anna@example.org": .has])
        #expect(note(answered, [anna, bo]) == .checking)
    }

    @Test func lockOffIsNotEncrypted() {
        let state = ComposeProtection(lockOn: false, mustAsk: false, recipients: ["anna@example.org": .has])
        #expect(note(state, [anna]) == .notEncrypted)
    }

    /// Wherever it goes unencrypted, it goes signed when signing is on.
    @Test func unencryptedWithSignIsSigned() {
        let off = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], signOn: true)
        #expect(note(off, [anna]) == .signed)
        let wish = ComposeProtection(
            lockOn: true, mustAsk: false, recipients: ["anna@example.org": .none], signOn: true)
        #expect(note(wish, [anna]) == .signed)
        let cannot = ComposeProtection(lockOn: true, mustAsk: false, recipients: [:], canProtect: false, signOn: true)
        #expect(note(cannot, [anna]) == .notEncrypted)
    }

    /// An account that can't protect: Send asks only when it must; with no lock there is no line.
    @Test func accountThatCannotProtect() {
        let asking = ComposeProtection(lockOn: true, mustAsk: true, recipients: [:], canProtect: false)
        #expect(note(asking, [anna]) == .cannotProtect)
        let wish = ComposeProtection(lockOn: true, mustAsk: false, recipients: [:], canProtect: false)
        #expect(note(wish, [anna]) == .notEncrypted)
        #expect(note(wish, [anna], fromStart: true) == .cannotProtect)
        let off = ComposeProtection(lockOn: false, mustAsk: false, recipients: [:], canProtect: false)
        #expect(note(off, [anna]) == nil)
    }

    @Test func noProtectionNoLine() {
        #expect(note(nil, [anna]) == nil)
    }
}
