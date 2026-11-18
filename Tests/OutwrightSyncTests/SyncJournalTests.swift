// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization
import OutwrightFakes
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

/// Every sync of a protocol and every send is noted in the diagnostics journal, by code.
@Suite final class SyncJournalTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-syncjournal-\(UUID().uuidString)", isDirectory: true)
    private lazy var journal = DiagnosticsJournal(fileURL: folder.appendingPathComponent("j.json")) { fixedNow }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func coordinator(_ h: Harness) -> SyncCoordinator {
        SyncCoordinator(
            store: h.store, secrets: h.secrets, now: { fixedNow }, resolver: FakeDoH(),
            davSession: URLSession(configuration: .ephemeral), probe: { _ in nil },
            reminders: RecordingReminders(), journal: journal)
    }

    /// The mail syncs noted (the harness account has contacts and calendars of its own too).
    private func syncEvents() -> [JournalEvent] {
        journal.entries().map(\.event).filter { if case .sync(_, .mail, _) = $0 { true } else { false } }
    }

    @Test func aRefreshNotesEachProtocol() async throws {
        try await withHarness { h in
            await coordinator(h).refreshAll()
            #expect(syncEvents() == [.sync(account: h.account.id, kind: .mail, code: nil)])
            let kinds = journal.entries().compactMap { if case .sync(_, let kind, _) = $0.event { kind } else { nil } }
            #expect(Set(kinds) == [.mail, .contacts, .calendar])
        }
    }

    @Test func aWrongPasswordIsNotedByCode() async throws {
        try await withHarness { h in
            try h.secrets.setPassword(.init("wrong"), for: h.account.id)
            await coordinator(h).refreshAll()
            #expect(syncEvents() == [.sync(account: h.account.id, kind: .mail, code: "imap.authenticationFailed")])
        }
    }

    @Test func theFirstUnreachableIsNotedToo() async throws {
        let server = await standardServer()
        try await withHarness(server) { h in
            await server.stop()
            await coordinator(h).refreshAll()
            let events = syncEvents()
            #expect(events.count == 1)
            if case .sync(_, .mail, let code) = events.first {
                #expect(code?.hasPrefix("imap.net") == true)
            } else {
                Issue.record("no mail sync noted: \(events)")
            }
        }
    }

    @Test func aSendIsNotedAsSendNotAsMail() async throws {
        let server = await standardServer()
        let data = try draftData()
        let serverDraft = await server.deliver(data, to: "Drafts", flags: ["\\Draft", "\\Seen"])
        try await withHarness(server, smtp: FakeSMTPServer(rejectRecipient: "bo@example.org")) { h in
            let syncer = AccountSyncer(
                account: h.account, store: h.store, credentials: CredentialProvider(secrets: h.secrets),
                now: { fixedNow }, journal: journal)
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let id = try localDraft(h, uid: serverDraft, data: data)
            try h.store.apply(.send(draftID: id))
            try? await syncer.runActions()
            let sends = journal.entries().map(\.event).filter { if case .send = $0 { true } else { false } }
            #expect(sends == [.send(account: h.account.id, code: "smtp.recipientRejected.550")])
            #expect(syncEvents().isEmpty)
        }
    }

    /// Two sends refused in one run are both noted as refused.
    @Test func twoRefusalsInOneRunAreBothNoted() async throws {
        try await withHarness(smtp: FakeSMTPServer(rejectRecipient: "bo@example.org")) { h in
            let syncer = AccountSyncer(
                account: h.account, store: h.store, credentials: CredentialProvider(secrets: h.secrets),
                now: { fixedNow }, journal: journal)
            try await syncer.syncFolders()
            for header in ["one@example.org", "two@example.org"] {
                let id = try localDraft(h, uid: 0, data: try draftData(messageID: header), header: header)
                try h.store.apply(.send(draftID: id))
            }
            try? await syncer.runActions()
            let sends = journal.entries().map(\.event).filter { if case .send = $0 { true } else { false } }
            #expect(sends == Array(repeating: .send(account: h.account.id, code: "smtp.recipientRejected.550"), count: 2))
        }
    }

    /// A refresh cut short (background time running out) says nothing about the account: no
    /// sync is noted, neither ok nor failed.
    @Test func aRefreshCutShortNotesNothing() async throws {
        let server = await standardServer()
        await server.deliver(mail("slow"), to: "INBOX")
        try await withHarness(server) { h in
            await server.delayFetches(.seconds(3))
            let coordinator = coordinator(h)
            let run = Task { await coordinator.refreshAll() }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while await server.sessionStarts.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(300))
            run.cancel()
            await run.value
            #expect(syncEvents().isEmpty, "\(syncEvents())")
        }
    }

    /// A watch that keeps failing the same way is noted once per quarter of an hour, not once a
    /// retry; a change of outcome is noted at once.
    @Test func aRepeatedFailureIsNotedOncePerQuarterHour() async throws {
        let clock = Mutex(fixedNow)
        try await withHarness { h in
            let coordinator = SyncCoordinator(
                store: h.store, secrets: h.secrets, now: { clock.withLock { $0 } }, resolver: FakeDoH(),
                davSession: URLSession(configuration: .ephemeral), probe: { _ in nil },
                reminders: RecordingReminders(), journal: journal)
            let id = h.account.id
            let failure = SyncError.imap(.net(.timeout))
            await coordinator.journalSync(id, .mail, failure)
            clock.withLock { $0 += 60 }
            await coordinator.journalSync(id, .mail, failure)
            #expect(syncEvents().count == 1)
            clock.withLock { $0 += 16 * 60 }
            await coordinator.journalSync(id, .mail, failure)
            #expect(syncEvents().count == 2)
            await coordinator.journalSync(id, .mail, nil)
            await coordinator.journalSync(id, .mail, failure)
            #expect(syncEvents().count == 4)
        }
    }

    @Test func aSearchWritesNothing() async throws {
        try await withHarness { h in
            let syncer = AccountSyncer(
                account: h.account, store: h.store, credentials: CredentialProvider(secrets: h.secrets),
                now: { fixedNow }, journal: journal)
            try await syncer.syncFolders()
            _ = try? await syncer.searchServer("anything", limit: 10)
            #expect(journal.entries().isEmpty)
        }
    }
}
