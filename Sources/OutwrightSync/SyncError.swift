// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightDAV
public import OutwrightGraph
public import OutwrightIMAP
public import OutwrightSMTP
public import OutwrightModel
import OutwrightStore

/// Why a synchronisation failed. Never carries a password, a token or message text.
public enum SyncError: Error, Sendable, Equatable {
    case imap(IMAPError)
    case smtp(SMTPError)
    /// A CardDAV request failed.
    case dav(DAVError)
    /// A Microsoft Graph request failed.
    case graph(GraphError)
    /// The store failed, or something held in it could not be used (a draft that won't read).
    case store(String)
    /// The keychain has no password for the account.
    case noPassword
    /// The keychain refused, with its status code.
    case keychain(Int32)
    /// The account's OAuth sign-in is gone (revoked, expired, or Conditional Access wants
    /// the owner): nothing is asked of the server until the owner signs in again.
    case needsSignIn(AccountID)
    /// An OAuth token could not be renewed this time (the network, the endpoint's own
    /// trouble); it is tried again next time.
    case oauth(OAuthError)
    /// The server does not offer signing in with a token (no `AUTH=XOAUTH2`).
    case noTokenSignIn
    /// A queued change whose message could not be found on the server, after several tries, was
    /// given up.
    case actionAbandoned
    /// The iPhone's Contacts refused a change (no access, or a failed save).
    case phoneContacts
    /// Outwright has no access to the iPhone's Contacts.
    case phoneContactsDenied
    /// A subscribed calendar could not be fetched or read.
    case subscription(SubscriptionFailure)
}

extension SyncError {
    /// The server refused a message for good (it is back in Drafts, marked); nil for anything else.
    public var sendRefusal: SendRefusal? {
        if case let .smtp(error) = self {
            return SendRefusal(error)
        }
        return nil
    }

    /// Whether the mail servers could not be reached (nothing was asked of them).
    var isUnreachable: Bool {
        switch self {
        case .imap(.net), .smtp(.net): true
        default: false
        }
    }

    /// Whether the IMAP connection is gone and has to be opened again.
    var breaksConnection: Bool {
        switch self {
        case .imap(.net), .imap(.protocolViolation): true
        default: false
        }
    }
}

/// Runs store calls, their error as a `SyncError`. (Generic over the closure's error because a
/// closure's typed throws is not inferred everywhere.)
func stored<T, E: Error>(_ body: () throws(E) -> T) throws(SyncError) -> T {
    do {
        return try body()
    } catch {
        throw .store(String(describing: error))
    }
}

/// Runs IMAP calls, their error as a `SyncError`.
func imap<T, E: Error>(_ body: () async throws(E) -> T) async throws(SyncError) -> T {
    do {
        return try await body()
    } catch {
        throw (error as? IMAPError).map(SyncError.imap) ?? .imap(.protocolViolation)
    }
}

/// Runs CardDAV calls, their error as a `SyncError`.
func dav<T, E: Error>(_ body: () async throws(E) -> T) async throws(SyncError) -> T {
    do {
        return try await body()
    } catch {
        throw (error as? DAVError).map(SyncError.dav) ?? .dav(.malformed)
    }
}
