// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightDAV
public import OutwrightModel

/// The DAV service looked for: contacts or calendars.
public enum DAVService: Sendable, Equatable {
    case cardDAV
    case calDAV

    /// The SRV name (RFC 6764) of the service over TLS, without the domain.
    var srvLabel: String {
        switch self {
        case .cardDAV: "_carddavs._tcp."
        case .calDAV: "_caldavs._tcp."
        }
    }

    var wellKnownPath: String {
        switch self {
        case .cardDAV: "/.well-known/carddav"
        case .calDAV: "/.well-known/caldav"
        }
    }
}

/// A CardDAV or CalDAV context found for an account.
public struct DAVFound: Sendable, Equatable {
    public var url: String
    /// The host is neither the address's domain (or below it) nor one of the account's mail
    /// hosts: ask the owner before a password goes there.
    public var offDomain: Bool

    public init(url: String, offDomain: Bool) {
        self.url = url
        self.offDomain = offDomain
    }
}

/// Finds an account's CardDAV or CalDAV context (RFC 6764): the service's SRV target
/// (`_carddavs._tcp` or `_caldavs._tcp`), else the domain, else the IMAP host, each asked at the
/// service's `/.well-known/` address without credentials.
public enum DAVDiscovery {
    /// Asks a `/.well-known/` address, without credentials, where it leads.
    public static let wellKnownProbe: @Sendable (URL) async -> URL? = { await WellKnown.probe($0) }

    public static func find(
        _ service: DAVService, for account: Account, resolver: any DoHResolving,
        probe: @Sendable (URL) async -> URL? = { await WellKnown.probe($0) }
    ) async -> DAVFound? {
        guard let domain = Discovery.domain(of: account.email) else {
            return nil
        }
        let imapHost = normalize(account.imap.host)
        var hosts: [(String, UInt16)] = []
        if let target = await srvTarget(service.srvLabel + domain, resolver) {
            hosts.append(target)
        }
        hosts.append((domain, 443))
        if Discovery.isHostName(imapHost, allowUnderscore: false) {
            hosts.append((imapHost, 443))
        }
        let candidates = hosts.compactMap { wellKnown($0.0, port: $0.1, path: service.wellKnownPath) }
        var tried: Set<String> = []
        for candidate in candidates where tried.insert(candidate.absoluteString).inserted {
            if let found = await probe(candidate), let host = found.host() {
                return DAVFound(url: found.absoluteString, offDomain: !trusted(host, domain: domain, account))
            }
        }
        return nil
    }

    /// On the address's domain or below it, or one of the account's own mail hosts.
    static func trusted(_ host: String, domain: String, _ account: Account) -> Bool {
        let host = normalize(host)
        let mailHosts = [account.imap.host, account.smtp.host].map(normalize)
        return host == domain || host.hasSuffix("." + domain) || mailHosts.contains(host)
    }

    private static func normalize(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    /// The SRV record of lowest priority with a usable target; "." means not offered.
    private static func srvTarget(
        _ name: String, _ resolver: any DoHResolving
    ) async -> (host: String, port: UInt16)? {
        let usable = await resolver.srv(name).compactMap { record -> SRVRecord? in
            let host = normalize(record.target)
            guard record.port != 0, Discovery.isHostName(host, allowUnderscore: false) else {
                return nil
            }
            return (host, record.port, record.priority)
        }
        return usable.min { $0.priority < $1.priority }.map { ($0.target, $0.port) }
    }

    private static func wellKnown(_ host: String, port: UInt16, path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = port == 443 ? nil : Int(port)
        parts.path = path
        return parts.url
    }
}
