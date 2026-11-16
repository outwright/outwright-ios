// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightNet
import Testing

@Suite struct EndpointTests {
    @Test func plainRefusedForRemoteHost() async {
        let endpoint = ServerEndpoint(host: "mail.example.org", port: 143, security: .plainLoopbackOnly)
        await #expect(throws: NetError.plainRefused) {
            _ = try await LineConnection.open(endpoint)
        }
    }

    @Test func secretNeverPrintsItsValue() {
        let secret = Secret("hunter2")
        #expect(secret.reveal() == "hunter2")
        #expect("\(secret)" == "<secret>")
        #expect(!String(reflecting: secret).contains("hunter2"))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }

    @Test func endpointRoundTripsThroughJSON() throws {
        let endpoint = ServerEndpoint(host: "imap.example.org", port: 993, security: .tls)
        let data = try JSONEncoder().encode(endpoint)
        #expect(try JSONDecoder().decode(ServerEndpoint.self, from: data) == endpoint)
    }
}
