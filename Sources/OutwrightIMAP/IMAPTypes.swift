// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a folder is for, from SPECIAL-USE (RFC 6154) or else its name.
public enum FolderRole: String, Codable, Sendable {
    case inbox, sent, drafts, trash, junk, archive, other
}

/// A mailbox as LIST names it.
public struct IMAPFolder: Sendable, Equatable {
    /// The server's name for the folder, as commands take it (modified UTF-7).
    public var path: String
    /// The last part of the path, decoded for display.
    public var name: String
    public var role: FolderRole
    public var selectable: Bool
    /// What separates the parts of the path (`/`, `.`); nil for a flat server.
    public var delimiter: String?

    public init(path: String, name: String, role: FolderRole, selectable: Bool, delimiter: String? = nil) {
        self.path = path
        self.name = name
        self.role = role
        self.selectable = selectable
        self.delimiter = delimiter
    }
}

/// What SELECT tells about a folder.
public struct FolderStatus: Sendable, Equatable {
    public var uidValidity: UInt32
    public var uidNext: UInt32
    public var exists: Int
    /// The folder's HIGHESTMODSEQ (RFC 7162); nil without CONDSTORE on, or for `[NOMODSEQ]`.
    public var highestModSeq: UInt64?

    public init(uidValidity: UInt32, uidNext: UInt32, exists: Int, highestModSeq: UInt64? = nil) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.exists = exists
        self.highestModSeq = highestModSeq
    }
}

/// What the connection has enabled of RFC 7162.
public enum ResyncMode: Sendable, Equatable {
    case qresync, condstore, none
}

/// Where a folder was last seen in step: a QRESYNC SELECT asks what changed since.
public struct QResyncPoint: Sendable, Equatable {
    public var uidValidity: UInt32
    public var modSeq: UInt64
    /// The span of uids held; the server answers only for these. Nil asks about the whole folder.
    public var known: ClosedRange<UInt32>?

    public init(uidValidity: UInt32, modSeq: UInt64, known: ClosedRange<UInt32>?) {
        self.uidValidity = uidValidity
        self.modSeq = modSeq
        self.known = known
    }
}

/// What a QRESYNC SELECT brought: uids expunged since the point, and flags changed since it.
public struct ResyncChanges: Sendable, Equatable {
    public var vanished: [ClosedRange<UInt32>]
    public var flags: [UInt32: Set<String>]

    public static let none = ResyncChanges(vanished: [], flags: [:])

    public init(vanished: [ClosedRange<UInt32>], flags: [UInt32: Set<String>]) {
        self.vanished = vanished
        self.flags = flags
    }
}

/// The parts of a message a folder list needs: its header block, the first 4 KiB of text, and the
/// calendar parts its structure names (an invitation in a multipart mail is not in its headers).
public struct MessageSummary: Sendable, Equatable {
    public var uid: UInt32
    public var flags: Set<String>
    public var internalDate: Date
    public var size: Int
    public var headers: Data
    public var partialText: Data
    public var calendarParts: [CalendarPartOutline]

    public init(
        uid: UInt32, flags: Set<String>, internalDate: Date, size: Int, headers: Data, partialText: Data,
        calendarParts: [CalendarPartOutline] = []
    ) {
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
        self.headers = headers
        self.partialText = partialText
        self.calendarParts = calendarParts
    }
}

/// Where the owner's own folders live (RFC 2342): `INBOX.` on a server that keeps them under
/// the Inbox, empty at the top.
public struct IMAPNamespace: Sendable, Equatable {
    public var prefix: String
    public var delimiter: String?

    public init(prefix: String, delimiter: String?) {
        self.prefix = prefix
        self.delimiter = delimiter
    }
}

/// A NAMESPACE answer kept for the connection, nil inside when there was none to use.
struct NamespaceAnswer: Sendable {
    var value: IMAPNamespace?
}
