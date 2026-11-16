// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightSync
import Testing


private func probe(_ h: Harness, marks: PushWatermarks) -> NewMailProbe {
    let account = h.account
    return NewMailProbe(
        account: { $0 == "sub-1" ? account : nil }, secrets: h.secrets, marks: marks)
}

@Suite final class NewMailProbeTests {
    /// The folder this test's watermark files live in, removed when the test is done.
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-marks-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A fresh watermark file in this test's folder.
    private func marksFile() -> URL {
        folder.appendingPathComponent("\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("push-watermarks.json")
    }

    @Test func firstRunSetsWatermarkWithoutNotifying() async throws {
        let server = await standardServer()
        for index in 0..<100 {
            await server.deliver(mail("old \(index)"), to: "INBOX")
        }
        try await withHarness(server) { h in
            let marks = PushWatermarks(fileURL: marksFile())
            let probe = probe(h, marks: marks)
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            #expect(await probe.run(subscriptionID: "sub-1") == .nothing)
            #expect(try marks.get("sub-1")?.lastUID == 100)
        }
    }

    @Test func newUnseenMessageIsReported() async throws {
        let server = await standardServer()
        await server.deliver(mail("old"), to: "INBOX")
        try await withHarness(server) { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await server.deliver(mail("Lunch?", from: "Bo Ek <bo@example.org>"), to: "INBOX")
            #expect(await probe.run(subscriptionID: "sub-1")
                == .mail([NewMail(sender: "Bo Ek", subject: "Lunch?")], count: 1))
            #expect(await probe.run(subscriptionID: "sub-1") == .nothing)
        }
    }

    @Test func aProtectedMessageIsReportedWithoutItsOuterSubject() async throws {
        let encrypted = Data(
            ("From: Bo Ek <bo@example.org>\r\nTo: jk@example.org\r\nSubject: ...\r\n"
                + "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"b\"\r\n\r\n"
                + "--b\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n--b--\r\n").utf8)
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await h.imap.deliver(encrypted, to: "INBOX")
            let result = await probe.run(subscriptionID: "sub-1")
            #expect(result == .mail([NewMail(sender: "Bo Ek", subject: "", isProtected: true)], count: 1))
            let notice = NewMailNotice(result, accountName: "Home", protectedBody: "Krypterat") { "\($0)" }
            #expect(notice == NewMailNotice(title: "Bo Ek", body: "Krypterat"))
        }
    }

    @Test func senderWithoutNameIsTheAddress() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await h.imap.deliver(mail("=?UTF-8?Q?R=C3=A4kor?=", from: "bo@example.org"), to: "INBOX")
            #expect(await probe.run(subscriptionID: "sub-1")
                == .mail([NewMail(sender: "bo@example.org", subject: "Räkor")], count: 1))
        }
    }

    @Test func seenMessageIsNotReported() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await h.imap.deliver(mail("read elsewhere"), to: "INBOX", flags: ["\\Seen"])
            #expect(await probe.run(subscriptionID: "sub-1") == .nothing)
        }
    }

    @Test func sixNewGiveFiveAndCountSix() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            for index in 1...6 {
                await h.imap.deliver(mail("new \(index)"), to: "INBOX")
            }
            let result = await probe.run(subscriptionID: "sub-1")
            let expected = (2...6).reversed().map { NewMail(sender: "bo@example.org", subject: "new \($0)") }
            #expect(result == .mail(expected, count: 6))
        }
    }

    @Test func concurrentProbesNotifyEachUIDOnce() async throws {
        try await withHarness { h in
            let file = marksFile()
            let first = probe(h, marks: PushWatermarks(fileURL: file))
            let second = probe(h, marks: PushWatermarks(fileURL: file))
            try await first.start(subscriptionID: "sub-1", account: h.account)
            await h.imap.deliver(mail("once"), to: "INBOX")
            async let one = first.run(subscriptionID: "sub-1")
            async let two = second.run(subscriptionID: "sub-1")
            let results = await [one, two]
            let mails = results.filter { if case .mail = $0 { true } else { false } }
            #expect(mails == [.mail([NewMail(sender: "bo@example.org", subject: "once")], count: 1)])
            #expect(results.filter { $0 == .nothing }.count == 1)
        }
    }

    @Test func uidValidityChangeResetsWithoutNotifying() async throws {
        let server = await standardServer()
        for index in 0..<3 {
            await server.deliver(mail("old \(index)"), to: "INBOX")
        }
        try await withHarness(server) { h in
            let marks = PushWatermarks(fileURL: marksFile())
            let probe = probe(h, marks: marks)
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await server.deliver(mail("rebuilt"), to: "INBOX")
            await server.renumber("INBOX", uidValidity: 4242)
            #expect(await probe.run(subscriptionID: "sub-1") == .nothing)
            #expect(try marks.get("sub-1") == PushWatermark(accountID: h.account.id, uidValidity: 4242, lastUID: 4))
            await server.deliver(mail("after"), to: "INBOX")
            #expect(await probe.run(subscriptionID: "sub-1")
                == .mail([NewMail(sender: "bo@example.org", subject: "after")], count: 1))
        }
    }

    /// A server may leave UIDNEXT out of SELECT: the mark comes from its newest message instead.
    @Test func missingUIDNextStillFindsNewMail() async throws {
        let server = await standardServer()
        for index in 0..<3 {
            await server.deliver(mail("old \(index)"), to: "INBOX")
        }
        await server.omitUIDNext()
        try await withHarness(server) { h in
            let marks = PushWatermarks(fileURL: marksFile())
            let probe = probe(h, marks: marks)
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            #expect(try marks.get("sub-1")?.lastUID == 3)
            #expect(await probe.run(subscriptionID: "sub-1") == .nothing)
            await server.deliver(mail("new"), to: "INBOX")
            #expect(await probe.run(subscriptionID: "sub-1")
                == .mail([NewMail(sender: "bo@example.org", subject: "new")], count: 1))
        }
    }

    @Test func missingUIDNextOnAnEmptyInboxStartsAtZero() async throws {
        let server = await standardServer()
        await server.omitUIDNext()
        try await withHarness(server) { h in
            let marks = PushWatermarks(fileURL: marksFile())
            let probe = probe(h, marks: marks)
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            #expect(try marks.get("sub-1")?.lastUID == 0)
            await server.deliver(mail("first"), to: "INBOX")
            #expect(await probe.run(subscriptionID: "sub-1")
                == .mail([NewMail(sender: "bo@example.org", subject: "first")], count: 1))
        }
    }

    @Test func probeGivesUpWithinBudget() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            await h.imap.deliver(mail("slow"), to: "INBOX")
            await h.imap.delayFetches(.seconds(5))
            let start = ContinuousClock.now
            #expect(await probe.run(subscriptionID: "sub-1", budget: .seconds(1)) == .failed)
            #expect(ContinuousClock.now - start < .seconds(2))
        }
    }

    @Test func wrongPasswordFails() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            try await probe.start(subscriptionID: "sub-1", account: h.account)
            try h.secrets.setPassword(.init("wrong"), for: h.account.id)
            #expect(await probe.run(subscriptionID: "sub-1") == .failed)
        }
    }

    @Test func unknownSubscriptionIsNothing() async throws {
        try await withHarness { h in
            let probe = probe(h, marks: PushWatermarks(fileURL: marksFile()))
            #expect(await probe.run(subscriptionID: "sub-unknown") == .nothing)
        }
    }

    @Test func watermarkFileGarbageIsTreatedAsEmpty() throws {
        let file = marksFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marks = PushWatermarks(fileURL: file)
        let mark = PushWatermark(accountID: AccountID(), uidValidity: 7, lastUID: 9)
        for garbage in [Data([0xFF, 0x00, 0x7B]), Data("{\"sub-1\": 12}".utf8), Data(repeating: 0x20, count: 70_000)] {
            try garbage.write(to: file)
            #expect(try marks.get("sub-1") == nil)
            try marks.set(mark, for: "sub-1")
            #expect(try marks.get("sub-1") == mark)
        }
    }

    @Test func advanceClaimsOnlyOnce() throws {
        let marks = PushWatermarks(fileURL: marksFile())
        try marks.set(PushWatermark(accountID: AccountID(), uidValidity: 7, lastUID: 9), for: "sub-1")
        #expect(try marks.advance("sub-1", validity: 7, to: 10))
        #expect(try !marks.advance("sub-1", validity: 7, to: 10))
        #expect(try !marks.advance("sub-1", validity: 8, to: 11))
        try marks.remove("sub-1")
        #expect(try marks.get("sub-1") == nil)
    }
}
