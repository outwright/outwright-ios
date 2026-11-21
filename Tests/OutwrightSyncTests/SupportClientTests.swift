// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Synchronization
import Testing

@testable import OutwrightSync

@Suite struct SupportClientTests {
    @Test func sendsTheFormAndReportWithoutAMailAccount() async throws {
        let received = Mutex<[FakeHTTPRequest]>([])
        let server = FakeHTTPServer { request in
            received.withLock { $0.append(request) }
            return .json(200, "{\"ok\":true}")
        }
        let port = try await server.start()
        defer { server.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/api/support"))
        let report = Data("synthetic diagnostics".utf8)
        try await SupportClient(endpoint: endpoint).send(
            SupportSubmission(email: "ada@example.org", message: "Cannot send mail", diagnostics: report))
        let request = try #require(received.withLock { $0.first })
        #expect(request.method == "POST")
        let body = try JSONDecoder().decode(SupportSubmission.self, from: request.body)
        #expect(body.email == "ada@example.org")
        #expect(body.message == "Cannot send mail")
        #expect(body.diagnostics == report)
    }

    @Test func deliveryMustBeConfirmedAndFailuresCanBeRetried() async throws {
        for (status, body) in [(503, "unavailable"), (200, "{\"ok\":false}"), (200, "not JSON")] {
            let server = FakeHTTPServer { _ in .init(status: status, body: Data(body.utf8)) }
            let port = try await server.start()
            defer { server.stop() }
            let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/api/support"))
            await #expect(throws: SupportSendError.failed) {
                try await SupportClient(endpoint: endpoint).send(
                    SupportSubmission(email: "ada@example.org", message: "Help", diagnostics: nil))
            }
        }
    }
}
