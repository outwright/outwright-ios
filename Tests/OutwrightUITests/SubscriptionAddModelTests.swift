// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightModel
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct SubscriptionAddModelTests {
    /// An app with no account: a subscribed calendar needs none.
    func make() throws -> AppModel {
        let box = try Mailbox()
        return AppModel(store: box.store, sync: offlineSync(store: box.store, secrets: InMemorySecretStore()))
    }

    @Test func checkFillsNameFromFeed() async throws {
        let app = try make()
        try await withFeed { address in
            let model = SubscriptionAddModel(app: app)
            model.address = address
            await model.check()
            #expect(model.state == .checked(SubscriptionPreview(name: "Work", events: 3)))
            #expect(model.name == "Work")
            model.name = "Jobb"
            await model.check()
            #expect(model.name == "Jobb")
        }
    }

    @Test func checkShowsFailure() async throws {
        let app = try make()
        let model = SubscriptionAddModel(app: app)
        model.address = "ftp://example.org/c.ics"
        await model.check()
        #expect(model.state == .failed(.badAddress))
    }

    @Test func saveNeedsACheck() async throws {
        let app = try make()
        try await withFeed { address in
            let model = SubscriptionAddModel(app: app)
            model.address = address
            model.name = "Work"
            #expect(await model.save() == nil)
            #expect(app.subscriptions().isEmpty)
            await model.check()
            #expect(await model.save() != nil)
            #expect(app.subscriptions().count == 1)
        }
    }

    @Test func editingAddressResetsCheck() async throws {
        let app = try make()
        try await withFeed { address in
            let model = SubscriptionAddModel(app: app)
            model.address = address
            await model.check()
            model.address = address + "x"
            #expect(model.state == .editing)
        }
    }

    @Test func addressChangedDuringCheckNeedsANewCheck() async throws {
        let app = try make()
        let server = FakeHTTPServer { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return FakeHTTPResponse(status: 200, body: SyntheticFeed.work)
        }
        let port = try await server.start()
        defer { server.stop() }
        let model = SubscriptionAddModel(app: app)
        model.address = "http://127.0.0.1:\(port)/a.ics"
        let checking = Task { await model.check() }
        try await Task.sleep(for: .milliseconds(100))
        model.address = "http://127.0.0.1:\(port)/b.ics"
        await checking.value
        #expect(model.state == .editing)
        #expect(await model.save() == nil)
    }
}
