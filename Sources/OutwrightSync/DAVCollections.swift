// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightDAV
public import OutwrightModel
public import OutwrightNet

/// Whether an account has anything behind a DAV address, asked with its password (#60): the lookup
/// that fills the address in asks without one, and only learns that the server speaks DAV.
public enum DAVCollections {
    /// True when the account has at least one calendar (`.calDAV`) or address book (`.cardDAV`) at
    /// `url`, false when the server lists none, and nil when it could not be told: a refused
    /// password, an unreachable server, an address that is no URL. The password goes only where
    /// `DAVTrust` allows.
    public static func exist(
        _ service: DAVService, at url: String, for account: Account, password: Secret,
        session: URLSession = .shared
    ) async -> Bool? {
        guard let context = URL(string: url), context.host() != nil else { return nil }
        let credentials = DAVCredentials(user: account.user, password: password.reveal())
        let trusted = DAVTrust.hosts(for: context, of: account)
        do {
            switch service {
            case .calDAV:
                let client = CalDAVClient(
                    context: context, credentials: credentials, trustedHosts: trusted, session: session)
                return try await !client.calendars().isEmpty
            case .cardDAV:
                let client = CardDAVClient(
                    context: context, credentials: credentials, trustedHosts: trusted, session: session)
                return try await !client.addressBooks().isEmpty
            }
        } catch {
            return nil
        }
    }
}
