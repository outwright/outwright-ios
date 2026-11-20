// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A change the owner made that the server has still to hear of.
public enum MailAction: Codable, Sendable, Equatable {
    case setRead(MessageID, Bool)
    case setFlagged(MessageID, Bool)
    case move(MessageID, to: FolderKind)
    case moveTo(MessageID, FolderID)
    case delete(MessageID)
    case send(draftID: MessageID)
    case saveDraft(MessageID)
    /// A message the server took for sending: its copy (the row, now in Sent) goes to the server's
    /// Sent once, and the draft it was sent from leaves the server's Drafts. Queued by the store when
    /// a send has gone, never by the owner.
    case fileSent(MessageID)
    /// A folder the owner made here, to be made on the server.
    case createFolder(FolderID)
    /// A folder renamed or moved: `from` and `to` are its whole paths; its subfolders follow.
    case renameFolder(FolderID, from: String, to: String)
    /// A folder deleted with its subfolders: each one the phone held, with the path it had.
    case deleteFolder(FolderID, paths: [FolderPath])

    /// The message the action is about; nil for a change to a folder.
    public var target: MessageID? {
        switch self {
        case let .setRead(id, _), let .setFlagged(id, _), let .move(id, _), let .moveTo(id, _), let .delete(id):
            id
        case let .send(id), let .saveDraft(id), let .fileSent(id):
            id
        case .createFolder, .renameFolder, .deleteFolder:
            nil
        }
    }
}

/// A folder change the server refused for good (`gaveUp`: or never took, after several tries),
/// undone on the phone and kept until the owner has seen it.
public struct FolderRefusal: Sendable, Equatable {
    /// The folder's name, as shown.
    public var name: String
    public var gaveUp: Bool

    public init(name: String, gaveUp: Bool) {
        self.name = name
        self.gaveUp = gaveUp
    }
}

/// A folder and the path it had when a change to it was queued.
public struct FolderPath: Codable, Sendable, Equatable {
    public var id: FolderID
    public var path: String
    /// What the folder was, to put it back as it was if the change is given up; nil in a change
    /// queued before these were kept.
    public var isFavorite: Bool?
    public var uidValidity: UInt32?

    public init(id: FolderID, path: String, isFavorite: Bool? = nil, uidValidity: UInt32? = nil) {
        self.id = id
        self.path = path
        self.isFavorite = isFavorite
        self.uidValidity = uidValidity
    }
}

/// Why the server refused a message for good. It stays in Drafts with this reason, and is not
/// tried again until the owner sends it again.
public enum SendRefusal: String, Codable, Sendable {
    /// The server would not take one of the recipients.
    case recipientRefused
    /// The server would not take the message (too large, refused by policy).
    case messageRefused
    /// A recipient is not an address the message can go to.
    case invalidRecipient
    /// An address has non-ASCII characters before the `@`, and the server cannot send it (no SMTPUTF8).
    case addressNeedsSMTPUTF8
    /// The message asks for a protection that is not here, or that was not chosen for these recipients.
    case protectionUnavailable
    /// The protection needs something of a recipient that is missing.
    case protectionKeyMissing
}
