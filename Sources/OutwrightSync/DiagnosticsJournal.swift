// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import Synchronization

/// What the protocols of an account are synced for.
public enum SyncKind: String, Codable, Sendable {
    case mail, calendar, contacts
}

/// One thing the diagnostics journal keeps. Only typed fields: codes, counts, times, sizes, ids
/// and fingerprints, never text from a server or a message.
public enum JournalEvent: Codable, Sendable, Equatable {
    case launch(version: String, build: String)
    /// One protocol's sync of an account; a nil code is a success.
    case sync(account: AccountID, kind: SyncKind, code: String?)
    /// Sending the account's queued mail; a nil code is a success.
    case send(account: AccountID, code: String?)
    /// One push, as the notification extension handled it.
    case push(
        subscription: String, why: ProbeWhy, count: Int?, shown: PushNoticeLog.Shown?, milliseconds: Int?,
        availableKB: Int?)
    case store(bytes: Int64, messages: Int)
    case migration(names: [String], milliseconds: Int)
}

public struct JournalEntry: Codable, Sendable, Equatable {
    public var date: Date
    public var event: JournalEvent

    public init(date: Date, event: JournalEvent) {
        self.date = date
        self.event = event
    }
}

/// The diagnostics journal: events the app and its notification extension note, one JSON line
/// each in one file (in the app group the two share), sent with Send diagnostics. A note appends a
/// line; past `trimSize` the file is written again with the newest `maxEntries` of the last
/// `kept` seconds. Reading keeps those too, skips a line that will not read, and starts again from
/// a file over `maxFileSize`. Writes are coordinated, so the two processes never lose each other's
/// events.
public final class DiagnosticsJournal: Sendable {
    public static let kept: TimeInterval = 7 * 86_400
    public static let maxEntries = 5_000
    static let trimSize = 1024 * 1024
    static let maxFileSize = 4 * 1024 * 1024

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let trims: Bool
    private let lock = Mutex(())

    /// `trims`: whether this writer rewrites the file once it grows past `trimSize`; the
    /// notification extension only appends, and the app trims.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init, trims: Bool = true) {
        self.fileURL = fileURL
        self.now = now
        self.trims = trims
    }

    /// The journal's file: in the app group's `container`, else in `fallback` (a build without one).
    public static func place(container: URL?, fallback: URL) -> URL {
        (container ?? fallback).appendingPathComponent("diagnostics-journal.json")
    }

    /// Adds one event; a write that fails is dropped, since the journal is only for looking at.
    public func note(_ event: JournalEvent) {
        let date = now()
        guard var line = try? Self.encoder.encode(JournalEntry(date: date, event: event)) else { return }
        line.append(0x0A)
        lock.withLock { _ in
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: fileURL, options: [], error: &coordinationError
            ) { url in
                Self.append(line, to: url)
                if trims, Self.size(url) > Self.trimSize {
                    Self.rewrite(Self.read(url, at: date), to: url)
                }
            }
        }
    }

    /// The kept entries, oldest first; empty when there are none or the file will not read.
    public func entries() -> [JournalEntry] {
        let date = now()
        return lock.withLock { _ in
            var entries: [JournalEntry] = []
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: fileURL, options: [], error: &coordinationError
            ) { url in
                entries = Self.read(url, at: date)
            }
            return entries
        }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Appends `line`, closing first a line a write cut short left open. A missing file is made and
    /// one past `maxFileSize` started again; a file that will not open otherwise (locked, say) costs
    /// only this note, never what is kept.
    private static func append(_ line: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) || size(url) > maxFileSize {
            rewrite([], to: url)
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd(), end > 0 {
            try? handle.seek(toOffset: end - 1)
            if (try? handle.read(upToCount: 1)) != Data([0x0A]) {
                try? handle.write(contentsOf: Data([0x0A]))
            }
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static func read(_ url: URL, at date: Date) -> [JournalEntry] {
        guard size(url) <= maxFileSize, let data = try? Data(contentsOf: url) else { return [] }
        let entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(JournalEntry.self, from: $0) }
        return Array(entries.filter { date.timeIntervalSince($0.date) < kept }.suffix(maxEntries))
    }

    private static func rewrite(_ entries: [JournalEntry], to url: URL) {
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
