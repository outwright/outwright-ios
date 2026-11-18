// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel

/// Who an account is with, as far as sync is concerned: how its OAuth tokens are renewed and
/// where its Graph is. A build registers its providers; the shared code asks them and never
/// names one.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    /// Renews the provider's OAuth tokens; nil for a provider whose accounts use passwords.
    var tokens: (any TokenRefreshing)? { get }
    /// Where the provider's Graph is; nil when it has none.
    var graphBase: URL? { get }
    /// The OAuth client id this build signs in with for the provider: a refresh token issued to
    /// another client id is not used here. Nil for a provider whose accounts use passwords.
    var oauthClientID: String? { get }
}

extension Provider {
    public var oauthClientID: String? { nil }
}

/// The owner's own server: passwords, IMAP and SMTP with CalDAV and CardDAV, or JMAP.
public struct OwnServerProvider: Provider {
    public let id = ProviderID.ownServer
    public let tokens: (any TokenRefreshing)? = nil
    public let graphBase: URL? = nil
    public init() {}
}

/// A build's providers, as the coordinator takes them.
public struct ProviderSet: Sendable {
    public let ids: [ProviderID]
    public let tokens: [ProviderID: any TokenRefreshing]
    public let graphBases: [ProviderID: URL]
    public let oauthClientIDs: [ProviderID: String]

    public init(_ providers: [any Provider]) {
        var ids: [ProviderID] = []
        var tokens: [ProviderID: any TokenRefreshing] = [:]
        var graphBases: [ProviderID: URL] = [:]
        var oauthClientIDs: [ProviderID: String] = [:]
        for provider in providers where !ids.contains(provider.id) {
            ids.append(provider.id)
            tokens[provider.id] = provider.tokens
            graphBases[provider.id] = provider.graphBase
            oauthClientIDs[provider.id] = provider.oauthClientID
        }
        self.ids = ids
        self.tokens = tokens
        self.graphBases = graphBases
        self.oauthClientIDs = oauthClientIDs
    }
}
