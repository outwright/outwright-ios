// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct ThreadingTests {
    let account = AccountID(raw: UUID())

    private func thread(
        _ messageID: String?, replyTo: [String] = [], refs: [String] = [], subject: String,
        uid: UInt32 = 1, isProtected: Bool = false, known: [String: ThreadID] = [:]
    ) -> ThreadID {
        Threading.threadID(
            messageID: messageID, inReplyTo: replyTo, references: refs, subject: subject,
            accountID: account, folderPath: "INBOX", uid: uid, isProtected: isProtected) { known[$0] }
    }

    @Test func joinsByReferences() {
        let known = ThreadID(raw: "root@example.org")
        let id = thread(
            "<c@example.org>", replyTo: ["<b@example.org>"],
            refs: ["<root@example.org>", "<b@example.org>"], subject: "Re: Hej",
            known: ["<root@example.org>": known])
        #expect(id == known)
    }

    @Test func protectedNeverJoinsBySubject() {
        let a = thread("<a@example.org>", replyTo: ["<x@example.org>"], subject: "...", isProtected: true)
        let b = thread("<b@example.org>", refs: ["<y@example.org>"], subject: "...", uid: 2, isProtected: true)
        #expect(a != b)
        #expect(a == ThreadID(raw: "<a@example.org>"))
    }

    @Test func usesOwnMessageIDWhenNotAReply() {
        #expect(thread("<a@example.org>", subject: "Hej") == ThreadID(raw: "<a@example.org>"))
    }

    @Test func replyWithUnknownReferencesFallsBackToNormalisedSubject() {
        let a = thread("<a@example.org>", replyTo: ["<x@example.org>"], subject: "Sv: VB: Möte")
        let b = thread("<b@example.org>", refs: ["<y@example.org>"], subject: "Re: Möte")
        #expect(a == b)
        #expect(a != ThreadID(raw: "<a@example.org>"))
    }

    @Test func messageWithoutIDGetsDeterministicLocalID() {
        let a = thread(nil, subject: "Hej", uid: 7)
        #expect(a == thread(nil, subject: "Hej", uid: 7))
        #expect(a != thread(nil, subject: "Hej", uid: 8))
    }
}
