// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
import OutwrightStore
public import OutwrightSync

/// A conversation as one thing to act on: the messages of a thread in one folder.
enum Conversation {
    /// The messages of `row`'s thread that are in `row`'s folder (the row itself at least).
    static func inFolder(of row: MessageRow, store: MailStore) throws(StoreError) -> [MessageRow] {
        let rows = try store.thread(row.threadID, account: row.accountID).filter { $0.folderID == row.folderID }
        return rows.isEmpty ? [row] : rows
    }

    /// Applies the action to each message; every one is tried, and the first failure is thrown after.
    static func apply(
        _ rows: [MessageRow], store: MailStore, _ action: (MessageID) -> MailAction
    ) throws(StoreError) {
        try apply(rows.map { action($0.id) }, store: store)
    }

    /// Applies each action; every one is tried, and the first failure is thrown after.
    static func apply(_ actions: [MailAction], store: MailStore) throws(StoreError) {
        var firstError: StoreError?
        for action in actions {
            do {
                try store.apply(action)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}

/// What went wrong with an account's synchronisation, in the owner's terms. Never server text.
public enum SyncProblem: Equatable, Sendable {
    case signIn, unreachable, encryption, keychain, storage, server
    /// An OAuth account's sign-in is gone: only the owner, signing in again, brings it back.
    case signInAgain
    /// The phone holds no password for the account, so nothing was sent to the server.
    case noPassword
    /// Contacts couldn't be saved to (or removed from) the iPhone's Contacts.
    case phoneContacts
    /// A message was refused for good and is back in Drafts.
    case notSent

    public init(_ error: SyncError) {
        if error.sendRefusal != nil {
            self = .notSent
            return
        }
        switch error {
        case .needsSignIn: self = .signInAgain
        case .noPassword: self = .noPassword
        case .imap(.authenticationFailed), .smtp(.authenticationFailed): self = .signIn
        case .imap(.startTLSNotOffered), .smtp(.startTLSNotOffered): self = .encryption
        case .imap(.net), .smtp(.net), .oauth(.transport), .graph(.net): self = .unreachable
        case .keychain: self = .keychain
        case .store: self = .storage
        case .phoneContacts: self = .phoneContacts
        default: self = .server
        }
    }

    /// A short reason, in the interface's language.
    var reason: String {
        switch self {
        case .signIn: L10n.string("Sign-in failed")
        case .signInAgain: L10n.string("Sign in again to keep getting mail")
        case .unreachable: L10n.string("Can't reach the server")
        case .encryption: L10n.string("The server doesn't offer encryption")
        case .keychain: L10n.string("The password couldn't be read")
        case .noPassword: L10n.string("No password on this phone. Enter it again.")
        case .storage: L10n.string("Mail couldn't be saved on this phone")
        case .server: L10n.string("The server refused")
        case .phoneContacts: L10n.string("Contacts couldn't be saved to the iPhone")
        case .notSent: L10n.string("A message wasn't sent. It's in Drafts.")
        }
    }
}

extension SendRefusal {
    /// Why a draft wasn't sent, in the interface's language. Never the server's text.
    var reason: String {
        switch self {
        case .recipientRefused: L10n.string("Not sent: the server refused a recipient.")
        case .messageRefused: L10n.string("Not sent: the server refused the message.")
        case .invalidRecipient: L10n.string("Not sent: a recipient is not an email address.")
        case .addressNeedsSMTPUTF8:
            L10n.string("Not sent: the server takes no address with letters such as å, ä or ö before the @.")
        case .protectionUnavailable: L10n.string("Not sent: the protection this message asks for is not available.")
        case .protectionKeyMissing: L10n.string("Not sent: a recipient's key is missing.")
        }
    }
}

/// One account's sync problem, for the banner.
public struct AccountProblem: Identifiable, Sendable {
    public var account: Account
    public var problem: SyncProblem
    public var id: AccountID { account.id }
}
