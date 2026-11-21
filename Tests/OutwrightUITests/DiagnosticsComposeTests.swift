// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

@MainActor @Suite struct AppDiagnosticsTests {
    @Test func theReportIsReadOffTheMainThread() async throws {
        var box = try Mailbox()
        try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        let onMain = Mutex<[Bool]>([])
        app.diagnostics = DiagnosticsSource(
            payloads: {
                onMain.withLock { $0.append(Thread.isMainThread) }
                return []
            },
            log: {
                onMain.withLock { $0.append(Thread.isMainThread) }
                return []
            })
        _ = await app.diagnosticsReport()
        #expect(onMain.withLock { $0 } == [false, false])
    }

    @Test func theReportHoldsPayloadsAndLogButNoAddresses() async throws {
        var box = try Mailbox()
        try box.addAccount("anna@example.org")
        let app = AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
        app.diagnostics = DiagnosticsSource(payloads: { [Data("{\"crash\":0}".utf8)] }, log: { ["started"] })
        let data = await app.diagnosticsReport()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains("{\"crash\":0}"))
        #expect(text.contains("started"))
        #expect(!text.contains("anna@example.org"))
    }
}
