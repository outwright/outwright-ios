// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Synchronization
import Testing

@testable import OutwrightDAV

/// The requests a server got.
final class SeenRequests: Sendable {
    let list = Mutex<[FakeHTTPRequest]>([])
}

@Suite struct FeedClientTests {
    let client = FeedClient(session: URLSession(configuration: .ephemeral))

    /// A server answering every request with `response`, and the requests it got.
    func serve(_ response: FakeHTTPResponse) async throws -> (FakeHTTPServer, URL, SeenRequests) {
        let seen = SeenRequests()
        let server = FakeHTTPServer { request in
            seen.list.withLock { $0.append(request) }
            return response
        }
        let port = try await server.start()
        return (server, try #require(URL(string: "http://127.0.0.1:\(port)/feed/calendar.ics")), seen)
    }

    @Test func bodyWithValidators() async throws {
        let body = SyntheticFeed.work
        let (server, url, _) = try await serve(
            FakeHTTPResponse(
                status: 200, body: body,
                headers: ["ETag": "\"a\"", "Last-Modified": "Wed, 11 Nov 2026 10:00:00 GMT"]))
        defer { server.stop() }
        let answer = try await client.fetch(url, etag: nil, lastModified: nil)
        #expect(answer == .body(body, etag: "\"a\"", lastModified: "Wed, 11 Nov 2026 10:00:00 GMT"))
    }

    @Test func conditionalHeadersSent() async throws {
        let (server, url, seen) = try await serve(FakeHTTPResponse(status: 304))
        defer { server.stop() }
        let answer = try await client.fetch(url, etag: "\"a\"", lastModified: "x")
        #expect(answer == .unchanged)
        let request = try #require(seen.list.withLock { $0.first })
        #expect(request.headers["if-none-match"] == "\"a\"")
        #expect(request.headers["if-modified-since"] == "x")
    }

    @Test func statusMapping() async throws {
        let cases: [(Int, DAVError)] = [
            (401, .unauthorized), (403, .unauthorized), (404, .notFound), (410, .notFound), (500, .status(500)),
        ]
        for (status, expected) in cases {
            let (server, url, _) = try await serve(FakeHTTPResponse(status: status))
            await #expect(throws: expected) { try await client.fetch(url, etag: nil, lastModified: nil) }
            server.stop()
        }
    }

    @Test func redirectToPlainRefused() async throws {
        let (server, url, _) = try await serve(
            FakeHTTPResponse(status: 302, headers: ["Location": "http://example.org/c.ics"]))
        defer { server.stop() }
        await #expect(throws: DAVError.plainRefused) { try await client.fetch(url, etag: nil, lastModified: nil) }
    }

    @Test func addressNormalizes() {
        #expect(FeedClient.address(" webcal://example.org/c.ics\n") == URL(string: "https://example.org/c.ics"))
        // A link broken across lines in a mail.
        #expect(FeedClient.address("https://example.org/owa/\n  calendar/c.ics") == URL(string: "https://example.org/owa/calendar/c.ics"))
        #expect(FeedClient.address("https://example.org/c.ics") == URL(string: "https://example.org/c.ics"))
        // Plain HTTP to loopback only, for tests.
        #expect(FeedClient.address("http://127.0.0.1:8080/c.ics") == URL(string: "http://127.0.0.1:8080/c.ics"))
        for bad in ["http://example.org/c.ics", "ftp://example.org/c.ics", "", "https://", "example.org/c.ics"] {
            #expect(FeedClient.address(bad) == nil)
        }
    }
}
