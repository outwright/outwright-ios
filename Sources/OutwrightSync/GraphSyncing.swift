// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightGraph
import OutwrightModel

/// What the Graph syncers (contacts, calendars) share: the client on the account's token, how a
/// Graph failure becomes a sync error, and the account's lock.
protocol GraphSyncing: Actor {
    var account: Account { get }
    var credentials: CredentialProvider { get }
    var lock: AccountLock { get }
    var base: URL { get }
    var session: URLSession { get }
    /// Replaced by another syncer for the account: does nothing more.
    var retired: Bool { get }
}

extension GraphSyncing {
    /// A Graph client on the account's token, or nil for an account that has nothing over Graph.
    /// The token is asked for first, so a refused sign-in is reported as such.
    func client() async throws(SyncError) -> GraphClient? {
        guard account.calendarVia == .graph || account.contactsVia == .graph else {
            return nil
        }
        _ = try await credentials.tokenSource(for: account.id, provider: account.provider).accessToken(for: .graph)
        return try credentials.graphClient(for: account, base: base, session: session)
    }

    /// Runs a Graph call; a final 401 means the owner must sign in again.
    func graph<T>(_ body: () async throws(GraphError) -> T) async throws(SyncError) -> T {
        do {
            return try await body()
        } catch .unauthorized {
            throw .needsSignIn(account.id)
        } catch {
            throw .graph(error)
        }
    }

    /// A failure on the server's side, not the connection, the sign-in or this phone's store.
    static func isServerTrouble(_ error: SyncError) -> Bool {
        guard case let .graph(graph) = error else { return false }
        switch graph {
        case .net, .unauthorized, .offHost, .plainRefused, .tooLarge, .throttled:
            return false
        case .notFound, .forbidden, .conflict, .preconditionFailed, .status, .malformed:
            return true
        }
    }

    /// Runs `body` with no other operation of this account in between.
    func exclusive<T>(_ body: () async throws(SyncError) -> T) async throws(SyncError) -> T {
        // A task cancelled while it waits gets no turn.
        guard await lock.acquire() else {
            throw .graph(.net)
        }
        guard !retired else {
            await lock.release()
            throw .graph(.net)
        }
        do {
            let result = try await body()
            await lock.release()
            return result
        } catch {
            await lock.release()
            throw error
        }
    }

    /// The folder (or calendar) path and the create id in a create target's href
    /// (`<path>#<create id>`); nil for any other shape.
    static func createTarget(_ href: String) -> (path: String, createID: String)? {
        let parts = href.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
