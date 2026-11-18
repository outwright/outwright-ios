// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import Synchronization

/// When a push subscription's server side was last renewed by the notification extension. (Files
/// from before kept how far the Inbox was announced too; those fields are ignored, the store keeps
/// that now.)
public struct PushWatermark: Codable, Sendable, Equatable {
    public var renewedAt: Date?

    public init(renewedAt: Date? = nil) {
        self.renewedAt = renewedAt
    }
}

/// The renewal marks of every push subscription, in one JSON file in the app group that the app
/// and its notification extensions share. Each change is a read-modify-write under a file
/// coordinator, so two processes never both claim a renewal. A file that will not read (garbage,
/// over 64 KiB) counts as empty.
public final class PushWatermarks: Sendable {
    static let maxFileSize = 64 * 1024

    private let fileURL: URL
    /// Serialises this object's own callers; the coordinator covers other processes.
    private let lock = Mutex(())

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The subscription is known from now on: its renewals may be claimed. One already known
    /// stays as it is.
    public func start(_ subscriptionID: String) throws(SyncError) {
        try change { marks in
            if marks[subscriptionID] == nil {
                marks[subscriptionID] = PushWatermark()
            }
        }
    }

    public func remove(_ subscriptionID: String) throws(SyncError) {
        try change { $0[subscriptionID] = nil }
    }

    /// Whether a renewal is due (none in the last `every`, or one dated in the future), and if so
    /// records `now` as the latest: one caller across processes gets each one. False for a
    /// subscription without a mark.
    func claimRenewal(_ subscriptionID: String, now: Date, every: TimeInterval) throws(SyncError) -> Bool {
        try change { marks in
            guard var mark = marks[subscriptionID] else {
                return false
            }
            if let last = mark.renewedAt, last <= now, now.timeIntervalSince(last) < every {
                return false
            }
            mark.renewedAt = now
            marks[subscriptionID] = mark
            return true
        }
    }

    /// Reads the marks, lets `body` change them, and writes them back when it did, all under
    /// one coordinated write.
    private func change<T: Sendable>(_ body: (inout [String: PushWatermark]) -> T) throws(SyncError) -> T {
        let result = lock.withLock { _ in
            Result { () throws(SyncError) -> T in try coordinated(body) }
        }
        return try result.get()
    }

    private func coordinated<T: Sendable>(_ body: (inout [String: PushWatermark]) -> T) throws(SyncError) -> T {
        var outcome: Result<T, SyncError> = .failure(.store("The push watermarks were not reached"))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: [], error: &coordinationError
        ) { url in
            outcome = Self.readModifyWrite(url, body)
        }
        if coordinationError != nil {
            throw .store("The push watermarks could not be opened")
        }
        return try outcome.get()
    }

    private static func readModifyWrite<T>(
        _ url: URL, _ body: (inout [String: PushWatermark]) -> T
    ) -> Result<T, SyncError> {
        let before = read(url)
        var marks = before
        let value = body(&marks)
        guard marks != before else {
            return .success(value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(marks), data.count <= maxFileSize else {
            return .failure(.store("The push watermarks are too large"))
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.store("The push watermarks could not be written"))
        }
        return .success(value)
    }

    /// The marks in the file; empty when it is missing, too large or not ours.
    private static func read(_ url: URL) -> [String: PushWatermark] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: PushWatermark].self, from: data)) ?? [:]
    }
}
