// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Reads a file the owner chose to attach, never more than the room left for attachments.
enum AttachmentReader {
    enum Outcome: Equatable {
        case read(Data)
        case tooLarge
        case unreadable
    }

    /// Reads at most one byte past `limit`, so a file of any size (or of a size the file system
    /// doesn't tell) is judged by what it holds, and a huge one is never read whole.
    static func read(_ url: URL, limit: Int) -> Outcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        let room = max(limit, 0)
        let wanted = room < Int.max ? room + 1 : room
        let data: Data
        do {
            data = try handle.read(upToCount: wanted) ?? Data()
        } catch {
            return .unreadable
        }
        return data.count > room ? .tooLarge : .read(data)
    }
}
