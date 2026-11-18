// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
public import Foundation
import Synchronization

/// The push notes from before the diagnostics journal (`DiagnosticsJournal`), still read for the
/// report; nothing writes them any more. What the notification extension found for each push, and
/// why: the time, the subscription's fingerprint, the reason, how many messages and what iOS was
/// handed, never the mail. One JSON file in the app group; a file that will not read (garbage,
/// over 64 KiB) counts as empty.
public final class PushNoticeLog: Sendable {
    public static let kept = 50
    static let maxFileSize = 64 * 1024

    /// What the notification iOS showed carried.
    public enum Shown: String, Codable, Sendable, Equatable {
        /// The extension's sender and subject, or "N new messages".
        case details
        /// The push's own generic text.
        case plain
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var date: Date
        public var why: ProbeWhy
        /// The subscription's `fingerprint`, as the relay logs it.
        public var subscription: String?
        /// How many new messages the probe found (only for `found`).
        public var count: Int?
        public var shown: Shown?

        public init(date: Date, why: ProbeWhy, subscription: String? = nil, count: Int? = nil, shown: Shown? = nil) {
            self.date = date
            self.why = why
            self.subscription = subscription
            self.count = count
            self.shown = shown
        }
    }

    /// A subscription told apart without naming it: the first 8 hex digits of its id's SHA-256,
    /// the same the relay logs, so one push can be followed through both logs.
    public static func fingerprint(_ subscriptionID: String) -> String {
        SHA256.hash(data: Data(subscriptionID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private let fileURL: URL
    private let lock = Mutex(())

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The kept entries, oldest first; empty when there are none or the file will not read.
    public func entries() -> [Entry] {
        lock.withLock { _ in
            var entries: [Entry] = []
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: fileURL, options: [], error: &coordinationError
            ) { url in
                entries = Self.read(url)
            }
            return entries
        }
    }

    /// The entries since `date` as report lines: ISO time, subscription, reason, count and what was shown.
    public func lines(since date: Date = .distantPast) -> [String] {
        entries().filter { $0.date >= date }.map { entry in
            var line = "\(entry.date.ISO8601Format()) push"
            if let subscription = entry.subscription { line += " \(subscription)" }
            line += " \(entry.why.rawValue)"
            if let count = entry.count { line += " count=\(count)" }
            if let shown = entry.shown { line += " shown=\(shown.rawValue)" }
            return line
        }
    }

    private static func read(_ url: URL) -> [Entry] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
            let data = try? Data(contentsOf: url),
            let entries = try? decoder.decode([Entry].self, from: data)
        else { return [] }
        return Array(entries.suffix(kept))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Why a push came to what it showed, for the notification log a tester can send. Never says what
/// the mail was. Cases no longer given (`allRead`, `alreadyAnnounced`, `restarted`) stay so that
/// older notes still read.
public enum ProbeWhy: String, Codable, Sendable, Equatable {
    /// Unseen mail above the mark: its sender and subject were shown.
    case found
    /// Nothing above the mark.
    case nothingNew
    /// New mail above the mark, but all of it already read.
    case allRead
    /// New unseen mail another probe (or the app) had already announced.
    case alreadyAnnounced
    /// No usable mark (new, renumbered or another account's): started again from now.
    case restarted
    /// The subscription belongs to no account any more.
    case unknownSubscription
    /// The server refused to sign the account in, or could not be reached for it.
    case signInFailed
    /// The server failed after signing in.
    case serverFailed
    /// The budget ran out before the server answered.
    case outOfTime
}
