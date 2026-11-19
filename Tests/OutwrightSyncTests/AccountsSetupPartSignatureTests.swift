// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A signature the owner wrote comes along; the default one stays each device's own.
@Suite struct AccountsSetupPartSignatureTests {
    static let english = "Sent from Outwright for iOS"
    static let swedish = "Skickat från Outwright för iOS"
    /// This device's default is the Swedish one; both languages' are defaults.
    static let rule = SignatureRule(isDefault: { [english, swedish].contains($0) }, defaultHere: { swedish })

    /// One device with one password account, signed as given.
    struct Device {
        let store: MailStore
        let secrets = InMemorySecretStore()
        let account: Account

        init(signature: String, password: String = "hunter2", account: Account = setupAccount("pat@example.org"))
            throws {
            store = try MailStore(path: nil)
            var account = account
            account.signature = signature
            self.account = account
            try store.save(account)
            try secrets.setPassword(Secret(password), for: account.id)
        }

        var part: AccountsSetupPart {
            AccountsSetupPart(
                store: store, secrets: secrets, providers: ProviderSet([OwnServerProvider()]),
                signatures: AccountsSetupPartSignatureTests.rule)
        }

        var signature: String? { try? store.accounts().first?.signature }
    }

    /// The same account (another id, as on another device), signed as given.
    func pair(there: String, here: String) async throws -> (content: Data, receiver: Device) {
        let content = try await Device(signature: there).part.export()
        return (content, try Device(signature: here))
    }

    @Test func newAccountWithDefaultSignatureGetsThisDevicesDefault() async throws {
        let content = try await Device(signature: Self.english).part.export()
        let empty = try MailStore(path: nil)
        let part = AccountsSetupPart(
            store: empty, secrets: InMemorySecretStore(), providers: ProviderSet([OwnServerProvider()]),
            signatures: Self.rule)

        _ = await part.importContent(content, version: 1)

        #expect(try empty.accounts().map(\.signature) == [Self.swedish])
    }

    @Test func newAccountWithHandwrittenSignatureKeepsIt() async throws {
        let content = try await Device(signature: "Pat, Example Org").part.export()
        let empty = try MailStore(path: nil)
        let part = AccountsSetupPart(
            store: empty, secrets: InMemorySecretStore(), providers: ProviderSet([OwnServerProvider()]),
            signatures: Self.rule)

        _ = await part.importContent(content, version: 1)

        #expect(try empty.accounts().map(\.signature) == ["Pat, Example Org"])
    }

    @Test func handwrittenOnBothThatDifferIsASignatureDifference() async throws {
        let (content, receiver) = try await pair(there: "Pat at work", here: "Pat on the phone")

        let differences = await receiver.part.differences(in: content)
        #expect(differences.map(\.kind) == [.signature])
        #expect(differences.map(\.id) == ["signature:pat@example.org"])

        _ = await receiver.part.importContent(content, version: 1, replacing: [])
        #expect(receiver.signature == "Pat on the phone")

        let report = await receiver.part.importContent(content, version: 1, replacing: ["signature:pat@example.org"])
        #expect(receiver.signature == "Pat at work")
        #expect(report.replaced == [accountItem("pat@example.org")])
        var unchanged = receiver.account
        unchanged.signature = "Pat at work"
        #expect(try receiver.store.accounts().map(encoded) == [try encoded(unchanged)])
        #expect(try receiver.secrets.password(for: receiver.account.id)?.reveal() == "hunter2")
    }

    @Test func handwrittenThereAndDefaultHereComesAlongWithoutAsking() async throws {
        let (content, receiver) = try await pair(there: "Pat at work", here: Self.swedish)

        #expect(await receiver.part.differences(in: content).isEmpty)
        let report = await receiver.part.importContent(content, version: 1, replacing: [])

        #expect(receiver.signature == "Pat at work")
        #expect(report.replaced == [accountItem("pat@example.org")])
    }

    @Test(arguments: ["Pat on the phone", ""])
    func defaultThereChangesNothingHere(_ here: String) async throws {
        let (content, receiver) = try await pair(there: Self.english, here: here)

        #expect(await receiver.part.differences(in: content).isEmpty)
        _ = await receiver.part.importContent(content, version: 1, replacing: [])

        #expect(receiver.signature == here)
    }

    @Test func emptyIsHandwritten() async throws {
        let (content, receiver) = try await pair(there: "Pat", here: "")

        #expect(await receiver.part.differences(in: content).map(\.kind) == [.signature])
    }

    @Test func defaultInAnotherLanguageIsNoDifference() async throws {
        let (content, receiver) = try await pair(there: Self.english, here: Self.swedish)

        #expect(await receiver.part.differences(in: content).isEmpty)
        let report = await receiver.part.importContent(content, version: 1, replacing: [])

        #expect(receiver.signature == Self.swedish)
        #expect(report.replaced.isEmpty)
    }

    @Test func passwordDifferenceIdAndState() async throws {
        let content = try await Device(signature: "Pat", password: "hunter2").part.export()
        let receiver = try Device(signature: "Pat", password: "chosen here")
        let other = try await Device(signature: "Pat", password: "hunter3").part.export()

        let first = try #require(await receiver.part.differences(in: content).first)
        let again = try #require(await receiver.part.differences(in: content).first)
        let changed = try #require(await receiver.part.differences(in: other).first)

        #expect(first.id == "password:pat@example.org")
        #expect(first.kind == .accountSecret)
        #expect(first.state == again.state)
        #expect(first.state != changed.state)
        #expect(!first.state.contains("hunter2") && !first.state.contains("chosen here"))
    }

    /// Each account is reported once: a refused secret is a failure even when its signature came along.
    @Test func aFailedSecretWithATakenSignatureIsReportedOnceAsFailed() async throws {
        let content = try await Device(signature: "Pat at work", password: "hunter2").part.export()
        let here = setupAccount("pat@example.org")
        let store = try MailStore(path: nil)
        var account = here
        account.signature = Self.swedish
        try store.save(account)
        let secrets = RefusingSecretStore(refusing: here.id)
        try secrets.inner.setPassword(Secret("chosen here"), for: here.id)
        let part = AccountsSetupPart(
            store: store, secrets: secrets, providers: ProviderSet([OwnServerProvider()]), signatures: Self.rule)

        let report = await part.importContent(content, version: 1, replacing: ["password:pat@example.org"])

        #expect(report.skipped == [SetupSkip(item: accountItem("pat@example.org"), reason: .failed)])
        #expect(report.replaced.isEmpty)
    }

    /// A secret filled in and a signature taken: one line, replaced.
    @Test func aFilledSecretWithATakenSignatureIsReportedOnce() async throws {
        let sender = try Device(signature: "Pat at work")
        let content = try await sender.part.export()
        let store = try MailStore(path: nil)
        var account = sender.account
        account.signature = Self.english
        try store.save(account)
        let part = AccountsSetupPart(
            store: store, secrets: InMemorySecretStore(), providers: ProviderSet([OwnServerProvider()]),
            signatures: Self.rule)

        let report = await part.importContent(content, version: 1)

        #expect(report.replaced == [accountItem("pat@example.org")])
        #expect(report.restored.isEmpty)
        #expect(report.skipped.isEmpty)
    }
}
