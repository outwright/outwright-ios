// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightStore

/// What opening the store did, for the diagnostics journal: the migrations it applied and their
/// time; and how much mail it holds.
@Suite final class MigrationTimingTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-migrated-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aNewStoreReportsItsMigrations() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MailStore(path: root.appendingPathComponent("mail.sqlite"))
        #expect(store.migrated.names.contains("v1"))
        #expect(store.migrated.seconds >= 0)
    }

    @Test func anOpenedCurrentStoreReportsNone() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("mail.sqlite")
        _ = try MailStore(path: path)
        #expect(try MailStore(path: path).migrated.names.isEmpty)
    }

    @Test func messageCountCountsAll() throws {
        let f = try Fixture()
        _ = try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1), row(f.account.id, f.sent.id, uid: 2, read: true)])
        #expect(try f.store.messageCount() == 2)
    }
}
