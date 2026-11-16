// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct AccountProviderTests {
    private func account(_ change: (inout Account) -> Void = { _ in }) -> Account {
        let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
        var account = Account(
            id: AccountID(raw: UUID()), displayName: "Anna", email: "anna@example.org", colorIndex: 0,
            imap: endpoint, smtp: endpoint, user: "anna@example.org", signature: "", sortOrder: 0)
        change(&account)
        return account
    }

    private func json(_ account: Account, _ edit: (inout [String: Any]) -> Void) throws -> Account {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func newAccountIsOwnServerOverDAV() {
        let plain = account()
        #expect(plain.provider == .ownServer)
        #expect(plain.auth == .password)
        #expect(plain.calendarVia == .calDAV)
        #expect(plain.contactsVia == .cardDAV)
    }

    @Test func roundTripsEveryField() throws {
        let original = account {
            $0.provider = ProviderID(raw: "example-mail")
            $0.auth = .oauth
            $0.calendarVia = .graph
            $0.contactsVia = .graph
        }
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(original))
        #expect(decoded.provider.raw == "example-mail")
        #expect(decoded.auth == .oauth)
        #expect(decoded.calendarVia == .graph)
        #expect(decoded.contactsVia == .graph)
    }

    @Test func jsonWithoutTheNewFieldsDecodesAsBefore() throws {
        let plain = try json(account()) { $0["auth"] = nil; $0["provider"] = nil; $0["calendarVia"] = nil; $0["contactsVia"] = nil }
        #expect(plain.provider == .ownServer)
        #expect(plain.auth == .password)
        #expect(plain.calendarVia == .calDAV)
    }

    /// A push registration written before providers carries `"auth":"microsoft"` and no provider.
    @Test func oldMicrosoftJSONBecomesTheMicrosoftProvider() throws {
        let old = try json(account()) {
            $0["auth"] = "microsoft"; $0["provider"] = nil; $0["calendarVia"] = nil; $0["contactsVia"] = nil
        }
        #expect(old.provider.raw == "microsoft")
        #expect(old.auth == .oauth)
        #expect(old.calendarVia == .graph)
        #expect(old.contactsVia == .graph)
    }

    @Test func unknownProviderDecodes() throws {
        let decoded = try json(account()) { $0["provider"] = "x-future" }
        #expect(decoded.provider.raw == "x-future")
    }
}
