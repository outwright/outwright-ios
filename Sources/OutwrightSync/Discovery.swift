// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
import OutwrightNet

/// The servers found for an address.
public struct DiscoveredServers: Sendable, Equatable {
    public var imap: MailEndpoint
    public var smtp: MailEndpoint
    /// A server is outside the address's domain (another company's host, or somebody who took
    /// over the DNS records): ask the owner before a password goes there.
    public var offDomain: Bool
    /// No SRV record named a server: the usual names for the domain are only a guess.
    public var guessed: Bool

    public init(imap: MailEndpoint, smtp: MailEndpoint, offDomain: Bool, guessed: Bool = false) {
        self.imap = imap
        self.smtp = smtp
        self.offDomain = offDomain
        self.guessed = guessed
    }
}

/// Finds an address's mail servers from its domain: SRV records for IMAP over TLS and for
/// submission (RFC 6186, RFC 8314), else the usual names. Only the domain is looked up.
public enum Discovery {
    public static func imapAndSMTP(
        for email: String, resolver: any DoHResolving
    ) async -> DiscoveredServers? {
        guard let domain = domain(of: email) else {
            return nil
        }
        let tls = TransportSecurity.tls.rawValue
        let foundIMAP = await best(resolver.srv("_imaps._tcp." + domain), security: tls)
        let imap = foundIMAP ?? MailEndpoint(host: "imap." + domain, port: 993, security: tls)
        var smtp = await best(resolver.srv("_submissions._tcp." + domain), security: tls)
        if smtp == nil {
            smtp = await best(resolver.srv("_submission._tcp." + domain), security: TransportSecurity.startTLS.rawValue)
        }
        let submission = smtp ?? MailEndpoint(host: "smtp." + domain, port: 465, security: tls)
        let outside = [imap.host, submission.host].contains { $0 != domain && !$0.hasSuffix("." + domain) }
        let guessed = foundIMAP == nil || smtp == nil
        return DiscoveredServers(imap: imap, smtp: submission, offDomain: outside, guessed: guessed)
    }

    /// The lower-case domain after the last `@`, when it is a plausible host name of two or more labels.
    public static func domain(of email: String) -> String? {
        guard let atSign = email.lastIndex(of: "@") else {
            return nil
        }
        var domain = email[email.index(after: atSign)...].lowercased()
        if domain.hasSuffix(".") {
            domain.removeLast()
        }
        guard isHostName(domain, allowUnderscore: false), domain.contains(".") else {
            return nil
        }
        return domain
    }

    /// ASCII letters, digits and hyphens (and underscores for service labels), labels of 1 to
    /// 63 characters that neither start nor end with a hyphen, 253 characters in all.
    static func isHostName(_ name: String, allowUnderscore: Bool) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253 else {
            return false
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                    || scalar == "-" || (allowUnderscore && scalar == "_")
            }
        }
    }

    /// The record of lowest priority with a usable target and port; "." means not offered.
    private static func best(_ records: [SRVRecord], security: String) -> MailEndpoint? {
        let usable = records.compactMap { record -> SRVRecord? in
            var host = record.target.lowercased()
            if host.hasSuffix(".") {
                host.removeLast()
            }
            guard record.port != 0, isHostName(host, allowUnderscore: false) else {
                return nil
            }
            return (host, record.port, record.priority)
        }
        guard let chosen = usable.min(by: { $0.priority < $1.priority }) else {
            return nil
        }
        return MailEndpoint(host: chosen.target, port: chosen.port, security: security)
    }
}
