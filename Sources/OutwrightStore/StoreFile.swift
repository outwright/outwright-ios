// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import GRDB

/// Where the store file is: moved once from where it was to where the app and its notification
/// extension share it, before it is opened.
public enum StoreFile {
    /// The journal before the main file, so a move cut short leaves the store at `old` until its
    /// main file has gone, and the next launch finishes it. The shared-memory index is SQLite's
    /// scratch, rebuilt on opening: it is removed, never moved. Answers `new`, or `old` when the
    /// move failed and the store is still there.
    public static func place(old: URL, new: URL) -> URL {
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path), files.fileExists(atPath: old.path) else {
            return new
        }
        do {
            try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(atPath: old.path + "-shm")
            if files.fileExists(atPath: old.path + "-wal") {
                try? files.removeItem(atPath: new.path + "-wal")
                try files.moveItem(atPath: old.path + "-wal", toPath: new.path + "-wal")
            }
            try files.moveItem(at: old, to: new)
            return new
        } catch {
            // The journal stays with the main file: one that moved without it comes back.
            if !files.fileExists(atPath: old.path + "-wal"), files.fileExists(atPath: new.path + "-wal") {
                try? files.moveItem(atPath: new.path + "-wal", toPath: old.path + "-wal")
            }
            return old
        }
    }
}

extension MailStore {
    /// Foreign keys on. The app and its notification extension share the file: a write that finds
    /// the other writing waits, and no lock is held while the app is suspended (iOS kills an app
    /// that keeps one on a shared file; the app suspends and resumes with the two below).
    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(10)
        config.observesSuspensionNotifications = true
        return config
    }

    /// Every store in this process lets go of its locks and refuses writes until `resumeSharing`:
    /// the app calls it before it may be suspended, since iOS kills a suspended app that holds a
    /// lock on a file it shares with its extension.
    public static func suspendSharing() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// The stores may write again.
    public static func resumeSharing() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Every list watching this store looks again: what another process (the notification
    /// extension) wrote is never seen otherwise.
    public func lookAgain() throws(StoreError) {
        try write { database in try database.notifyChanges(in: .fullDatabase) }
    }
}

/// The migrations opening a store applied, and how long they took.
public struct Migrated: Sendable, Equatable {
    public var names: [String]
    public var seconds: Double
}

extension MailStore {
    /// Brings the store up to date, saying what that applied.
    static func migrate(_ queue: any DatabaseWriter) throws -> Migrated {
        let migrator = Schema.migrator()
        let before = try queue.read { try migrator.appliedIdentifiers($0) }
        let clock = ContinuousClock()
        let start = clock.now
        try migrator.migrate(queue)
        let took = clock.now - start
        let after = try queue.read { try migrator.appliedIdentifiers($0) }
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let applied = migrator.migrations.filter { after.contains($0) && !before.contains($0) }
        return Migrated(names: applied, seconds: seconds)
    }

    /// Every message held, in every folder of every account.
    public func messageCount() throws(StoreError) -> Int {
        try read { database in try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM message") ?? 0 }
    }
}
