// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public enum FolderKind: String, Codable, Sendable {
    case inbox, sent, drafts, trash, junk, archive, other
}

public struct Folder: Sendable, Identifiable, Equatable {
    public var id: FolderID
    public var accountID: AccountID
    public var path: String
    public var name: String
    public var kind: FolderKind
    public var uidValidity: UInt32
    /// Filled by the store from the messages it holds.
    public var unread: Int
    public var isFavorite: Bool
    /// The server's hierarchy delimiter (`/`, `.`), nil where the folder stands alone.
    public var delimiter: String?

    public init(
        id: FolderID, accountID: AccountID, path: String, name: String, kind: FolderKind,
        uidValidity: UInt32, unread: Int, isFavorite: Bool, delimiter: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.path = path
        self.name = name
        self.kind = kind
        self.uidValidity = uidValidity
        self.unread = unread
        self.isFavorite = isFavorite
        self.delimiter = delimiter
    }
}
