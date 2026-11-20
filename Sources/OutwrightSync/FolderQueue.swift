// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// The owner's folder changes still waiting for the server, read over what the server lists, so
/// a sync never undoes one that hasn't reached the server yet.
enum FolderQueue {
    /// `listed` as it will be once `queued` (the account's changes, oldest first) has run: renamed
    /// paths rewritten, deleted folders left out, folders made here kept. A rewritten folder takes
    /// what the store knows of it at its new path (its number, name and favourite mark).
    static func project(_ listed: [Folder], known: [Folder], queued: [MailAction]) -> [Folder] {
        var result = listed
        let byPath = Dictionary(known.map { ($0.path, $0) }) { first, _ in first }
        for action in queued {
            switch action {
            case let .renameFolder(_, from, to):
                result = result.map { folder in
                    guard let rest = remainder(of: folder.path, under: from, delimiter: folder.delimiter) else {
                        return folder
                    }
                    var moved = folder
                    moved.path = to + rest
                    if let held = byPath[moved.path] {
                        moved.name = held.name
                        moved.uidValidity = held.uidValidity
                        moved.isFavorite = held.isFavorite
                    }
                    return moved
                }
            case let .deleteFolder(_, paths):
                result.removeAll { folder in
                    paths.contains { remainder(of: folder.path, under: $0.path, delimiter: folder.delimiter) != nil }
                }
            case let .createFolder(id):
                if let made = known.first(where: { $0.id == id }), !result.contains(where: { $0.path == made.path }) {
                    var kept = made
                    kept.id = FolderID(raw: 0)
                    result.append(kept)
                }
            default:
                continue
            }
        }
        return result
    }

    /// True while the server can't have the folder at its path yet: its own creation, or a rename
    /// of it or of a folder above it, is still queued.
    static func waits(_ folder: Folder, queued: [MailAction]) -> Bool {
        queued.contains { action in
            switch action {
            case let .createFolder(id):
                id == folder.id
            case let .renameFolder(_, _, to):
                remainder(of: folder.path, under: to, delimiter: folder.delimiter) != nil
            default:
                false
            }
        }
    }

    /// What follows `top` in `path` when `path` is `top` or under it (`""` for `top` itself); nil
    /// otherwise.
    static func remainder(of path: String, under top: String, delimiter: String?) -> String? {
        if path == top {
            return ""
        }
        guard let delimiter, !delimiter.isEmpty, path.hasPrefix(top + delimiter) else {
            return nil
        }
        return String(path.dropFirst(top.count))
    }
}
