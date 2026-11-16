// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import Synchronization
import Testing

@testable import OutwrightSync

@Suite struct DiscoveryTests {
    @Test func discoveryUsesSRVThenFallback() async throws {
        let resolver = FakeDoH([
            "_imaps._tcp.example.org": [
                (target: "backup.example.org.", port: 993, priority: 20),
                (target: "mail.example.org.", port: 993, priority: 10),
            ],
            "_submissions._tcp.example.org": [(target: "smtp.example.org.", port: 465, priority: 0)],
            "_submission._tcp.plain.example": [(target: "relay.plain.example.", port: 587, priority: 0)],
            "_imaps._tcp.none.example": [(target: ".", port: 0, priority: 0)],
        ])

        let found = try #require(await Discovery.imapAndSMTP(for: "jk@Example.org", resolver: resolver))
        #expect(found.imap == MailEndpoint(host: "mail.example.org", port: 993, security: "tls"))
        #expect(found.smtp == MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"))
        #expect(found.offDomain == false)

        let plain = try #require(await Discovery.imapAndSMTP(for: "a@plain.example", resolver: resolver))
        #expect(plain.imap == MailEndpoint(host: "imap.plain.example", port: 993, security: "tls"))
        #expect(plain.smtp == MailEndpoint(host: "relay.plain.example", port: 587, security: "startTLS"))

        // "." says the service is not offered: the usual names are tried instead.
        let none = try #require(await Discovery.imapAndSMTP(for: "a@none.example", resolver: resolver))
        #expect(none.imap == MailEndpoint(host: "imap.none.example", port: 993, security: "tls"))
        #expect(none.smtp == MailEndpoint(host: "smtp.none.example", port: 465, security: "tls"))
        #expect(none.offDomain == false)

        // Only the domain is ever asked about, never the mailbox name.
        #expect(!resolver.asked.isEmpty)
        #expect(resolver.asked.allSatisfy { !$0.contains("jk") && !$0.contains("@") })
    }

    @Test func serversOutsideTheDomainAreSaidToBe() async throws {
        let resolver = FakeDoH([
            "_imaps._tcp.example.org": [(target: "imap.hoster.example.", port: 993, priority: 0)],
            "_submissions._tcp.other.example": [(target: "smtp.hoster.example.", port: 465, priority: 0)],
            "_imaps._tcp.sub.example": [(target: "mail.sub.example.", port: 993, priority: 0)],
            "_submissions._tcp.sub.example": [(target: "x.mail.sub.example.", port: 465, priority: 0)],
            "_imaps._tcp.evil.example": [(target: "notevil.example.", port: 993, priority: 0)],
        ])
        #expect(await Discovery.imapAndSMTP(for: "a@example.org", resolver: resolver)?.offDomain == true)
        #expect(await Discovery.imapAndSMTP(for: "a@other.example", resolver: resolver)?.offDomain == true)
        #expect(await Discovery.imapAndSMTP(for: "a@sub.example", resolver: resolver)?.offDomain == false)
        // A name that merely ends in the same letters is another domain.
        #expect(await Discovery.imapAndSMTP(for: "a@evil.example", resolver: resolver)?.offDomain == true)
    }

    @Test func lookupSendsAGenericAgentAndNoLanguage() async throws {
        let seen = HeaderLog()
        let listener = FakeListener { connection in
            var lines: [String] = []
            while let line = await connection.readLine(), !line.isEmpty {
                lines.append(String(decoding: line, as: UTF8.self))
            }
            seen.set(lines)
            let body = #"{"Status":0,"Answer":[{"type":33,"data":"0 0 993 mail.example.org."}]}"#
            connection.send(Data((
                "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n" + body).utf8))
            connection.close()
        }
        let port = try await listener.start()
        let records = await CloudflareDoH(endpoint: "http://127.0.0.1:\(port)/dns-query", timeout: 60).srv("_imaps._tcp.example.org")
        listener.stop()
        #expect(records.first?.target == "mail.example.org.")
        let headers = seen.lines.dropFirst().map { $0.lowercased() }
        #expect(headers.contains("user-agent: outwright"))
        // URLSession always writes the header; what matters is that it names no language.
        #expect(headers.filter { $0.hasPrefix("accept-language:") }.allSatisfy { $0 == "accept-language: " })
        #expect(!headers.contains { $0.hasPrefix("cookie:") })
        #expect(seen.lines.first?.hasPrefix("GET /dns-query?name=_imaps._tcp.example.org&type=SRV ") == true)
    }

    @Test(arguments: ["nobody", "a@", "a@localhost", "a@exa mple.org", "a@-bad.example", "a@b..example", "a@b.example\r\nX"])
    func addressWithoutAUsableDomainFindsNothing(_ email: String) async {
        let resolver = FakeDoH()
        #expect(await Discovery.imapAndSMTP(for: email, resolver: resolver) == nil)
        #expect(resolver.asked.isEmpty)
    }

    @Test func hostileSRVTargetsAreIgnored() async throws {
        let resolver = FakeDoH([
            "_imaps._tcp.example.org": [
                (target: "evil host\r\n.example.", port: 993, priority: 0),
                (target: "mail.example.org", port: 0, priority: 0),
            ],
        ])
        let found = try #require(await Discovery.imapAndSMTP(for: "jk@example.org", resolver: resolver))
        #expect(found.imap.host == "imap.example.org")
    }

    @Test func cloudflareAnswerIsReadForSRVRecordsOnly() {
        let json = Data("""
            {"Status":0,"Answer":[
              {"name":"_imaps._tcp.example.org","type":33,"TTL":300,"data":"10 5 993 mail.example.org."},
              {"name":"_imaps._tcp.example.org","type":5,"TTL":300,"data":"other.example.org."},
              {"name":"_imaps._tcp.example.org","type":33,"TTL":300,"data":"x y z"},
              {"name":"_imaps._tcp.example.org","type":33,"TTL":300,"data":"1 1 99999 big.example.org."}
            ]}
            """.utf8)
        let records = CloudflareDoH.records(from: json)
        #expect(records.count == 1)
        #expect(records.first?.target == "mail.example.org.")
        #expect(records.first?.port == 993)
        #expect(records.first?.priority == 10)
        #expect(CloudflareDoH.records(from: Data("not json".utf8)).isEmpty)
        #expect(CloudflareDoH.records(from: Data(#"{"Status":2}"#.utf8)).isEmpty)
    }

    @Test func cloudflareAnswerIsReadForMailExchangersOnly() {
        let json = Data("""
            {"Status":0,"Answer":[
              {"name":"example.org","type":15,"TTL":300,"data":"10 Mail.Example.org."},
              {"name":"example.org","type":5,"TTL":300,"data":"other.example.org."},
              {"name":"example.org","type":15,"TTL":300,"data":"x"},
              {"name":"example.org","type":15,"TTL":300,"data":"20 a b"},
              {"name":"example.org","type":15,"TTL":300,"data":"0 ."}
            ]}
            """.utf8)
        let exchanges = CloudflareDoH.exchanges(from: json)
        #expect(exchanges.map(\.host) == ["mail.example.org"])
        #expect(exchanges.map(\.preference) == [10])
        #expect(CloudflareDoH.exchanges(from: Data("not json".utf8)).isEmpty)
        #expect(CloudflareDoH.exchanges(from: Data(#"{"Status":2}"#.utf8)).isEmpty)
    }

    @Test func cloudflareIsAskedForMailExchangersByName() throws {
        let request = try #require(CloudflareDoH.request(for: "example.org", type: "MX"))
        let parts = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(Set(parts.queryItems ?? []) == [
            URLQueryItem(name: "name", value: "example.org"), URLQueryItem(name: "type", value: "MX"),
        ])
    }

    @Test func cloudflareIsAskedForTheNameAndNothingElse() throws {
        let request = try #require(CloudflareDoH.request(for: "_imaps._tcp.example.org"))
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == "cloudflare-dns.com")
        #expect(parts.path == "/dns-query")
        #expect(Set(parts.queryItems ?? []) == [
            URLQueryItem(name: "name", value: "_imaps._tcp.example.org"), URLQueryItem(name: "type", value: "SRV"),
        ])
        #expect(request.httpShouldHandleCookies == false)
        #expect(CloudflareDoH.request(for: "a b\r\n") == nil)
    }
}

/// The request lines a fake HTTP server saw.
final class HeaderLog: Sendable {
    private let store = Mutex<[String]>([])

    var lines: [String] {
        store.withLock { $0 }
    }

    func set(_ lines: [String]) {
        store.withLock { $0 = lines }
    }
}
