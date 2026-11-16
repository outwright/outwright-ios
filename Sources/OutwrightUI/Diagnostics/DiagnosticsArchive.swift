// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The MetricKit payloads kept on the phone for a diagnostics report: a folder of `<epoch-ms>.json`
/// files, the newest 14 kept, none over 1 MiB. Nothing here ever fails the app: a file it can't
/// write, read or parse is passed over.
public struct DiagnosticsArchive: Sendable {
    /// How many payloads are kept, and the largest one.
    static let capacity = 14
    static let largest = 1 << 20

    private let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Keeps a payload, then removes all but the newest `capacity`. One over `largest` is dropped.
    public func keep(_ payload: Data, at date: Date) {
        guard payload.count <= Self.largest,
            var stamp = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded())
        else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // A payload kept in the same millisecond as another (from this thread or another) takes the
        // next free one, so neither is lost: a file that exists is never written over.
        for _ in 0..<Self.capacity * 2 {
            let url = folder.appendingPathComponent("\(stamp).json")
            if (try? payload.write(to: url, options: .withoutOverwriting)) != nil { break }
            let (next, overflow) = stamp.addingReportingOverflow(1)
            guard !overflow else { return }
            stamp = next
        }
        for (_, url) in files().dropFirst(Self.capacity) {
            try? manager.removeItem(at: url)
        }
    }

    /// The kept payloads that are JSON and not oversized, newest first, at most `capacity`.
    public func recent() -> [Data] {
        var found: [Data] = []
        for (_, url) in files() {
            guard found.count < Self.capacity else { break }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.largest,
                let data = try? Data(contentsOf: url), data.count <= Self.largest,
                (try? JSONSerialization.jsonObject(with: data)) != nil
            else { continue }
            found.append(data)
        }
        return found
    }

    /// The archive's own files (a number and `.json`), newest first; anything else is left alone.
    private func files() -> [(Int64, URL)] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url -> (Int64, URL)? in
            guard url.pathExtension == "json", let stamp = Int64(url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return (stamp, url)
        }
        .sorted { $0.0 > $1.0 }
    }
}
