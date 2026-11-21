// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Synchronization
import Testing

@Suite struct HTTPSessionTests {
    /// A server's answer is never kept: the same request, answered as cacheable for an hour, reaches the
    /// server again, so nothing a server sent is held outside the store.
    @Test func aCacheableAnswerIsNotKept() async throws {
        let asked = Mutex(0)
        let server = FakeHTTPServer { _ in
            asked.withLock { $0 += 1 }
            return FakeHTTPResponse(
                status: 200, body: Data("contact".utf8),
                headers: ["Cache-Control": "public, max-age=3600", "Content-Type": "text/plain"])
        }
        let port = try await server.start()
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/card.vcf"))
        let session = HTTPSession.shared
        for _ in 0..<2 {
            let (data, _) = try await session.data(from: url)
            #expect(data == Data("contact".utf8))
        }
        #expect(asked.withLock { $0 } == 2)
    }
}
