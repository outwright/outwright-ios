// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// A protection that records what it was told to learn from.
private final class Learner: MailProtection, @unchecked Sendable {
    let id = ProtectionID(raw: "learner")
    let learned = Mutex<[String]>([])
    func headers(for account: Account) async -> [(name: String, value: String)] { [] }
    func protect(_ message: OutgoingMessage, requirement: ProtectionRequirement, account: Account)
        async throws(ProtectionFailure) -> ProtectedSend {
        ProtectedSend(submissions: [], ownCopy: Data())
    }
    func protectDraft(_ raw: Data, account: Account) async -> Data? { nil }
    func learn(from message: MIMEMessage, facts: ProtectionFacts?, folder: FolderKind, account: Account) async {
        learned.withLock { $0.append("\(message.subject)|\(folder.rawValue)") }
    }
}

@Suite struct OpeningSyncTests {
    @Test func aFetchedBodyIsLearnedFromOnce() async throws {
        let server = await standardServer()
        await server.deliver(mail("Hello", id: "h@example.org"), to: "INBOX")
        try await withHarness(server) { h in
            let learner = Learner()
            let syncer = AccountSyncer(
                account: h.account, store: h.store, secrets: h.secrets, now: { fixedNow }, protections: [learner])
            try await syncer.syncFolders()
            try await syncer.sync(try h.folder(.inbox).id)
            let row = try #require(try h.rows(.inbox).first)
            try await syncer.fetchBody(row.id)
            #expect(learner.learned.withLock { $0 } == ["Hello|inbox"])
        }
    }
}
