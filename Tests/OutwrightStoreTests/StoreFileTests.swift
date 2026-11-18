// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import GRDB
import OutwrightModel
import Testing

@testable import OutwrightStore

/// The store moves once into the folder the app shares with its notification extension, and the
/// two can write it side by side.
@Suite final class StoreFileTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-storefile-\(UUID().uuidString)", isDirectory: true)
    private var old: URL { root.appendingPathComponent("old/mail.sqlite") }
    private var new: URL { root.appendingPathComponent("new/mail.sqlite") }

    init() throws {
        for folder in ["old", "new"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func exists(_ url: URL, _ suffix: String = "") -> Bool {
        FileManager.default.fileExists(atPath: url.path + suffix)
    }

    /// A store at `old` holding one account (closed, as at a launch).
    private func oldStore() throws -> Account {
        let store = try MailStore(path: old)
        let account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        try store.save(account)
        return account
    }

    @Test func movesTheStoreWithItsJournal() throws {
        let account = try oldStore()
        #expect(StoreFile.place(old: old, new: new) == new)
        #expect(!exists(old) && !exists(old, "-wal"))
        #expect(try MailStore(path: new).accounts().map(\.id) == [account.id])
    }

    @Test func keepsAStoreAlreadyThere() throws {
        _ = try oldStore()
        let kept = try MailStore(path: new)
        let mine = Fixture.makeAccount(name: "Bo", email: "bo@example.org", order: 0)
        try kept.save(mine)
        #expect(StoreFile.place(old: old, new: new) == new)
        #expect(try MailStore(path: new).accounts().map(\.id) == [mine.id])
    }

    @Test func aMoveCutShortIsFinished() throws {
        let account = try oldStore()
        // Killed after the journal moved, before the main file did.
        try FileManager.default.moveItem(atPath: old.path + "-wal", toPath: new.path + "-wal")
        #expect(StoreFile.place(old: old, new: new) == new)
        #expect(!exists(old))
        #expect(try MailStore(path: new).accounts().map(\.id) == [account.id])
    }

    @Test func nothingToMoveAnswersNew() {
        #expect(StoreFile.place(old: old, new: new) == new)
    }

    @Test func twoStoresOnOneFileWriteInTurn() async throws {
        let first = try MailStore(path: new)
        let second = try MailStore(path: new)
        await withTaskGroup(of: Void.self) { group in
            for (index, store) in [first, second, first, second].enumerated() {
                group.addTask {
                    for round in 0..<20 {
                        let account = Fixture.makeAccount(
                            name: "A\(index)-\(round)", email: "a\(index)-\(round)@example.org", order: round)
                        try? store.save(account)
                    }
                }
            }
        }
        #expect(try first.accounts().count == 80)
    }
}

/// The notification extension opens only a store the app has brought up to date: it never
/// migrates one, which the app may be doing at the same moment.
@Suite final class CurrentStoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-current-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aCurrentStoreOpens() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("mail.sqlite")
        try MailStore(path: path).save(Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0))
        #expect(try MailStore(current: path).accounts().count == 1)
    }

    @Test func anOlderStoreIsNotMigrated() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("mail.sqlite")
        let pool = try DatabasePool(path: path.path)
        try Schema.migrator().migrate(pool, upTo: "v1")
        try pool.close()
        #expect(throws: StoreError.self) { try MailStore(current: path) }
        let after = try DatabaseQueue(path: path.path)
        #expect(try after.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM grdb_migrations WHERE identifier = 'pushMailMarks'") } == nil)
    }
}

/// The app's lists notice what the notification extension stored once told to look again: GRDB
/// only sees its own writes.
@Suite final class OtherWritesTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-other-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    actor Seen {
        var counts: [Int] = []
        func add(_ count: Int) { counts.append(count) }
    }

    @Test func theListsSeeTheExtensionsMailWhenToldToLookAgain() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("mail.sqlite")
        let app = try MailStore(path: path)
        let account = Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0)
        try app.save(account)
        try app.replaceFolders(Fixture.folders(for: account.id), for: account.id)
        let inbox = try #require(try app.folders(account.id).first { $0.kind == .inbox })
        let seen = Seen()
        let stream = app.observe(InboxQuery(scope: .folder(inbox.id), inboxClass: nil, filter: .all))
        let reader = Task { for await rows in stream { await seen.add(rows.count) } }
        defer { reader.cancel() }
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(5)
        while await seen.counts.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try MailStore(current: path).upsert([row(account.id, inbox.id, uid: 1)])
        try app.lookAgain()
        deadline = clock.now + .seconds(5)
        while await seen.counts.last != 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await seen.counts.last == 1)
    }
}
