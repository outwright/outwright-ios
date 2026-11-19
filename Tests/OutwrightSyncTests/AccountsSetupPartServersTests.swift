// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

/// An account's servers changed on one device: the owner is asked whether this one takes them.
@Suite struct AccountsSetupPartServersTests {
    struct Device {
        let store: MailStore
        let secrets = InMemorySecretStore()
        let account: Account

        init(_ account: Account, password: String = "hunter2") throws {
            store = try MailStore(path: nil)
            self.account = account
            try store.save(account)
            switch account.auth {
            case .password: try secrets.setPassword(Secret(password), for: account.id)
            case .oauth: try secrets.setRefreshToken(Secret("refresh-1"), for: account.id)
            }
        }

        var part: AccountsSetupPart {
            AccountsSetupPart(
                store: store, secrets: secrets,
                providers: ProviderSet([OwnServerProvider(), ClientProvider(id: cloud, oauthClientID: "client-a")]))
        }
    }

    /// The account as on the other device: moved to new servers, with another user name.
    static func moved(_ account: Account) -> Account {
        var moved = account
        moved.id = AccountID()
        moved.imap = MailEndpoint(host: "imap.new.example.org", port: 993, security: "tls")
        moved.smtp = MailEndpoint(host: "smtp.new.example.org", port: 587, security: "starttls")
        moved.user = "pat"
        return moved
    }

    @Test func serverDifferenceIsReported() async throws {
        let here = try Device(setupAccount("pat@example.org"))
        let content = try await Device(Self.moved(here.account)).part.export()

        let differences = await here.part.differences(in: content)

        #expect(differences.map(\.kind) == [.servers])
        #expect(differences.map(\.id) == ["servers:pat@example.org"])
        #expect(differences.map(\.label) == ["pat@example.org"])
        #expect(differences.allSatisfy { !$0.state.isEmpty })
    }

    @Test func sameServersIsNoDifference() async throws {
        let here = try Device(setupAccount("pat@example.org"))
        var same = here.account
        same.id = AccountID()
        let content = try await Device(same).part.export()

        #expect(await here.part.differences(in: content).isEmpty)
    }

    @Test func serversReplacedKeepsTheRest() async throws {
        let here = try Device(setupAccount("pat@example.org"))
        let inbox = Folder(
            id: FolderID(raw: 0), accountID: here.account.id, path: "INBOX", name: "Inbox", kind: .inbox,
            uidValidity: 7, unread: 0, isFavorite: false)
        try here.store.replaceFolders([inbox], for: here.account.id)
        let moved = Self.moved(here.account)
        let content = try await Device(moved, password: "other").part.export()

        _ = await here.part.importContent(content, version: 1, replacing: [])
        #expect(try here.store.accounts().map(\.imap) == [here.account.imap])

        let report = await here.part.importContent(content, version: 1, replacing: ["servers:pat@example.org"])

        var expected = here.account
        expected.imap = moved.imap
        expected.smtp = moved.smtp
        expected.user = moved.user
        #expect(try here.store.accounts().map(encoded) == [try encoded(expected)])
        #expect(try here.secrets.password(for: here.account.id)?.reveal() == "hunter2")
        #expect(try here.store.folders(here.account.id).map(\.path) == ["INBOX"])
        #expect(report.replaced == [accountItem("pat@example.org")])
    }

    @Test func differentProviderIsNoServerDifference() async throws {
        let here = try Device(setupAccount("olle@example.org", auth: .oauth, provider: cloud))
        var there = Self.moved(here.account)
        there.provider = .ownServer
        there.auth = .password
        let content = try await Device(there).part.export()

        #expect(await here.part.differences(in: content).filter { $0.kind == .servers }.isEmpty)
    }
}
