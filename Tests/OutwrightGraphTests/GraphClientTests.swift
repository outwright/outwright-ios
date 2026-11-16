// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightGraph

@Suite struct GraphClientTests {
    @Test func bearerTokenIsSent() async throws {
        try await withGraph { server, client, _ in
            _ = try await client.folders()
            let request = try #require(await server.requests.first)
            #expect(request.headers["authorization"] == "Bearer token-1")
        }
    }

    /// An etag from the server and the token go into headers with CR, LF and NUL taken out.
    @Test func headerValuesCarryNoLineBreaks() async throws {
        try await withGraph { server, client, renewals in
            renewals.token.withLock { $0 = "token-1\r\nX-Injected: 1" }
            let id = await server.put(json(fullContact))
            try await client.delete(id: id, ifMatch: "W/\"\r\n1\0\"")
            let request = try #require(await server.requests.last)
            #expect(request.headers["x-injected"] == nil)
            #expect(request.headers["authorization"] == "Bearer token-1X-Injected: 1")
            #expect(request.headers["if-match"] == "W/\"1\"")
        }
    }

    @Test func plainHTTPOnlyToLoopback() async throws {
        let base = try #require(URL(string: "http://graph.example.org/v1.0/"))
        let client = GraphClient(base: base, token: { "t" }, renew: { _ in false })
        await #expect(throws: GraphError.plainRefused) { try await client.folders() }
    }

    @Test func nextLinkOffHostIsRefused() async throws {
        try await withGraph { server, client, _ in
            await server.put(json(["displayName": "A"]))
            await server.nextLinkTo(host: "elsewhere.example.org")
            await #expect(throws: GraphError.offHost) {
                try await client.contacts(in: GraphFolder.defaultFolder)
            }
            #expect(await server.requests.count == 1)
        }
    }

    @Test func pagesStopAtTheCap() async throws {
        try await withGraph { server, client, _ in
            await server.endlessPages()
            await #expect(throws: GraphError.tooLarge) { try await client.contacts(in: GraphFolder.defaultFolder) }
            #expect(await server.requests.count == GraphClient.maxPages)
        }
    }

    @Test func pagesAreFollowed() async throws {
        try await withGraph { server, client, _ in
            for index in 0..<5 { await server.put(json(["displayName": "P\(index)"])) }
            await server.setPageSize(2)
            let found = try await client.contacts(in: GraphFolder.defaultFolder)
            #expect(found.map(\.fields.displayName) == ["P0", "P1", "P2", "P3", "P4"])
        }
    }

    /// Pages each under the answer cap still stop once the listing as a whole passes its cap.
    @Test func aListingStopsAtItsTotalCap() async throws {
        try await withGraph { server, client, _ in
            let big = String(repeating: "x", count: 1 << 20)
            for _ in 0..<40 { await server.put(json(["personalNotes": big])) }
            await server.setPageSize(2)
            await #expect(throws: GraphError.tooLarge) { try await client.contacts(in: GraphFolder.defaultFolder) }
            #expect(await server.requests.count <= GraphClient.maxListing / (2 << 20) + 1)
        }
    }

    @Test func answerPastCapIsTooLarge() async throws {
        try await withGraph { server, client, _ in
            let huge = String(repeating: "x", count: 1 << 20)
            for _ in 0..<5 { await server.put(json(["personalNotes": huge])) }
            await #expect(throws: GraphError.tooLarge) { try await client.contacts(in: GraphFolder.defaultFolder) }
        }
    }

    @Test func unauthorizedRenewsOnceThenFails() async throws {
        try await withGraph { server, client, renewals in
            await server.setAcceptedTokens(["token-2"])
            _ = try await client.folders()
            #expect(renewals.count.withLock { $0 } == 1)

            await server.setAcceptedTokens([])
            await #expect(throws: GraphError.unauthorized) { try await client.folders() }
            #expect(renewals.count.withLock { $0 } == 2)
        }
    }

    @Test(arguments: [(404, GraphError.notFound), (412, .preconditionFailed), (429, .throttled), (503, .throttled),
                      (500, .status(500)), (400, .status(400))])
    func statusCodesMap(status: Int, expected: GraphError) async throws {
        try await withGraph { server, client, _ in
            await server.failNext(status: status)
            await #expect(throws: expected) { try await client.folders() }
        }
    }

    @Test func arbitraryBytesNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        let pieces = [#"{"value":["#, #"{"id":"#, #""x""#, "1", "null", "[", "]", "{", "}", ",", ":", #""@odata.etag""#,
                      #""emailAddresses""#, #""homeAddress""#, "true", #""\u0000""#]
        for _ in 0..<2000 {
            var data = Data()
            if Bool.random(using: &generator) {
                data = Data((0..<Int.random(in: 0..<64, using: &generator)).map { _ in
                    UInt8.random(in: 0...255, using: &generator)
                })
            } else {
                let count = Int.random(in: 0..<24, using: &generator)
                let text = (0..<count).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
                data = Data(text.utf8)
            }
            _ = try? GraphContacts.page(data)
            _ = GraphContacts.contact(data)
        }
    }
}
