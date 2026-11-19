// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Synchronization
import Testing

@testable import OutwrightSync

/// Small Argon2 parameters, so a test seals in milliseconds.
let quick = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)

/// A part only a later build has: it exports, and nothing reads it here.
struct FuturePart: SetupPart {
    let name = "future"
    let title = "Future things"
    let version = 1
    func export() async throws(SetupError) -> Data { Data("{\"keys\":[1,2]}".utf8) }
    func summary(of content: Data) throws(SetupError) -> [SetupItem] { [] }
    func items() async -> [SetupItem] { [] }
    func importContent(_ content: Data, version: Int) async -> SetupImportReport { SetupImportReport() }
}

@Suite struct SetupExchangeTests {
    struct Device {
        let store: MailStore
        let secrets = InMemorySecretStore()

        init() throws { store = try MailStore(path: nil) }

        func parts(extra: [any SetupPart] = []) -> [any SetupPart] {
            [
                SubscriptionsSetupPart(store: store, secrets: secrets),
                AccountsSetupPart(
                    store: store, secrets: secrets,
                    providers: ProviderSet([OwnServerProvider(), ClientProvider(id: cloud, oauthClientID: "client-a")]))
            ] + extra
        }

        func exchange(extra: [any SetupPart] = []) -> SetupExchange {
            SetupExchange(parts: parts(extra: extra), device: "Test phone", parameters: quick, secrets: secrets)
        }
    }

    /// A device with one account and one subscribed calendar.
    func sender() throws -> Device {
        let device = try Device()
        let account = setupAccount("pat@example.org")
        try device.store.save(account)
        try device.secrets.setPassword(Secret("hunter2"), for: account.id)
        let key = UUID()
        _ = try device.store.addSubscription(key: key, host: "cal.example.org", name: "Holidays", color: 0x2E9E6B)
        try device.secrets.setSubscriptionAddress(Secret("https://cal.example.org/s3cret/holidays.ics"), for: key)
        return device
    }

    @Test func subscriptionsMoveWithTheirAddresses() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange().makeFile(passphrase: passphrase)
        let receiver = try Device()

        let preview = try await receiver.exchange().preview(file, passphrase: passphrase)
        let report = await receiver.exchange().restore(preview)

        #expect(report.added.contains(SetupItem(kind: .calendar, label: "Holidays")))
        let restored = try receiver.store.subscriptions()
        #expect(restored.map(\.calendar.name) == ["Holidays"])
        #expect(restored.map(\.host) == ["cal.example.org"])
        #expect(restored.map(\.calendar.color) == [0x2E9E6B])
        let key = try #require(restored.first?.key)
        let address = try receiver.secrets.subscriptionAddress(key)?.reveal()
        #expect(address == "https://cal.example.org/s3cret/holidays.ics")
    }

    @Test func calendarAlreadyHereIsSkipped() async throws {
        let passphrase = try Passphrase.generate()
        let device = try sender()
        let file = try await device.exchange().makeFile(passphrase: passphrase)

        let report = await device.exchange().restore(try await device.exchange().preview(file, passphrase: passphrase))

        #expect(report.added.isEmpty)
        #expect(Set(report.skipped.map(\.reason)) == [.alreadyHere])
        #expect(try device.store.subscriptions().count == 1)
    }

    @Test func unknownPartIsListedNotMoved() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange(extra: [FuturePart()]).makeFile(passphrase: passphrase)
        let receiver = try Device()

        let preview = try await receiver.exchange().preview(file, passphrase: passphrase)
        // Shown by the title its writer gave it.
        #expect(preview.notInThisBuild == ["Future things"])
        #expect(preview.items.map(\.name) == ["accounts", "subscriptions"])

        let report = await receiver.exchange().restore(preview)
        let future = SetupItem(kind: .part, label: "Future things")
        #expect(report.skipped == [SetupSkip(item: future, reason: .notInThisBuild)])
        #expect(try receiver.store.accounts().map(\.email) == ["pat@example.org"])
        #expect(try receiver.store.subscriptions().count == 1)
    }

    /// Files made before settings stopped coming along hold a `settings` part: it is passed over,
    /// never shown as left out.
    @Test func retiredSettingsPartIsSkippedSilently() async throws {
        var (bundle, _) = try await sender().exchange().exportBundle()
        bundle.parts["settings"] = SetupBundle.Part(
            version: 1, title: "Settings", content: Data("{\"values\":{\"focusedInbox\":true}}".utf8))
        let receiver = try Device()

        let preview = await receiver.exchange().preview(bundle)
        #expect(preview.notInThisBuild.isEmpty)
        #expect(preview.unreadable.isEmpty)

        let report = await receiver.exchange().restore(preview)
        #expect(!report.skipped.contains { $0.item.kind == .part })
        #expect(try receiver.store.accounts().map(\.email) == ["pat@example.org"])
    }

    @Test func exportBundleHoldsEveryPart() async throws {
        let exchange = try sender().exchange(extra: [FuturePart()])
        let (bundle, items) = try await exchange.exportBundle()

        #expect(Set(bundle.parts.keys) == ["accounts", "subscriptions", "future"])
        #expect(bundle.device == "Test phone")
        #expect(bundle.parts["future"]?.title == "Future things")
        #expect(items.contains(SetupItem(kind: .account, label: "pat@example.org")))
        #expect(items.contains(SetupItem(kind: .calendar, label: "Holidays")))
    }

    @Test func previewOfABundleMatchesPreviewOfTheFile() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange(extra: [FuturePart()]).makeFile(passphrase: passphrase)
        let receiver = try Device().exchange()

        let bundle = try SetupBundle.opened(file, passphrase: passphrase)
        #expect(await receiver.preview(bundle) == (try await receiver.preview(file, passphrase: passphrase)))
        #expect(await receiver.preview(bundle).notInThisBuild == ["Future things"])
    }

    @Test func corruptFileRestoresNothing() async throws {
        let passphrase = try Passphrase.generate()
        var file = try await sender().exchange().makeFile(passphrase: passphrase)
        let receiver = try Device()
        let middle = file.index(file.startIndex, offsetBy: file.count / 2)
        file[middle] ^= 0x01

        await #expect(throws: SetupError.self) { try await receiver.exchange().preview(file, passphrase: passphrase) }
        #expect(try receiver.store.accounts().isEmpty)
        #expect(try receiver.store.subscriptions().isEmpty)
    }

    @Test func accountsAreRestoredFirst() async throws {
        let order = OrderLog()
        let parts: [any SetupPart] = ["b", "accounts", "a"].map { RecordingPart(name: $0, log: order) }
        let exchange = SetupExchange(parts: parts, device: "Test phone", parameters: quick)
        let passphrase = try Passphrase.generate()
        let file = try await exchange.makeFile(passphrase: passphrase)

        _ = await exchange.restore(try await exchange.preview(file, passphrase: passphrase))

        #expect(order.names == ["accounts", "a", "b"])
    }
}

/// A part this build reads, whose content it cannot read.
struct BrokenPart: SetupPart {
    let name = "broken"
    let title = "Broken things"
    let version = 1
    func export() async throws(SetupError) -> Data { Data("{}".utf8) }
    func summary(of content: Data) throws(SetupError) -> [SetupItem] { throw .malformed }
    func items() async -> [SetupItem] { [] }
    func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        Issue.record("an unreadable part is never imported")
        return SetupImportReport()
    }
}

extension SetupExchangeTests {
    /// One part that cannot be read is listed as such; the others are restored.
    @Test func aPartThatCannotBeReadDoesNotStopTheOthers() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange(extra: [RenamedPart(inner: FuturePart(), name: "broken")])
            .makeFile(passphrase: passphrase)
        let receiver = try Device()
        let exchange = receiver.exchange(extra: [BrokenPart()])

        let preview = try await exchange.preview(file, passphrase: passphrase)
        #expect(preview.unreadable == ["Broken things"])
        #expect(preview.items.map(\.name) == ["accounts", "subscriptions"])

        let report = await exchange.restore(preview)
        #expect(report.skipped == [SetupSkip(item: SetupItem(kind: .part, label: "Broken things"), reason: .failed)])
        #expect(try receiver.store.accounts().map(\.email) == ["pat@example.org"])
        #expect(try receiver.store.subscriptions().count == 1)
    }

    /// A part with neither a title nor a name fit to show is listed with an empty title, for the
    /// screens to name.
    @Test func aPartWithNothingFitToShowIsListedWithoutATitle() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange(extra: [RenamedPart(inner: FuturePart(), name: "odd\u{202E}")])
            .makeFile(passphrase: passphrase)
        let receiver = try Device()

        let preview = try await receiver.exchange().preview(file, passphrase: passphrase)
        #expect(preview.notInThisBuild == [""])
        let report = await receiver.exchange().restore(preview)
        #expect(report.skipped == [SetupSkip(item: SetupItem(kind: .part, label: ""), reason: .notInThisBuild)])
    }

    /// A phone restored from an iCloud or Finder backup: its store came back, its keychain did not.
    /// The file fills in the secrets and leaves the rest as the device has it.
    @Test func aDeviceWithRowsButNoSecretsGetsTheSecretsFilledIn() async throws {
        let passphrase = try Passphrase.generate()
        let original = try sender()
        let file = try await original.exchange().makeFile(passphrase: passphrase)
        let restored = try Device()
        for account in try original.store.accounts() { try restored.store.save(account) }
        for subscription in try original.store.subscriptions() {
            _ = try restored.store.addSubscription(
                key: subscription.key, host: subscription.host, name: "Renamed here",
                color: subscription.calendar.color)
        }

        let preview = try await restored.exchange().preview(file, passphrase: passphrase)
        let report = await restored.exchange().restore(preview)

        #expect(report.added.isEmpty)
        #expect(Set(report.restored) == [
            SetupItem(kind: .account, label: "pat@example.org"), SetupItem(kind: .calendar, label: "Holidays")
        ])
        let account = try #require(try restored.store.accounts().first)
        #expect(try restored.secrets.password(for: account.id)?.reveal() == "hunter2")
        let subscription = try #require(try restored.store.subscriptions().first)
        #expect(try restored.secrets.subscriptionAddress(subscription.key)?.reveal()
            == "https://cal.example.org/s3cret/holidays.ics")
        #expect(subscription.calendar.name == "Renamed here")
    }
}

/// Another part's export under a name of its own.
struct RenamedPart: SetupPart {
    let inner: any SetupPart
    let name: String
    var title: String { name }
    var version: Int { inner.version }
    func export() async throws(SetupError) -> Data { try await inner.export() }
    func summary(of content: Data) throws(SetupError) -> [SetupItem] { try inner.summary(of: content) }
    func items() async -> [SetupItem] { await inner.items() }
    func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        await inner.importContent(content, version: version)
    }
}

final class OrderLog: Sendable {
    private let held = Mutex<[String]>([])
    var names: [String] { held.withLock { $0 } }
    func add(_ name: String) { held.withLock { $0.append(name) } }
}

struct RecordingPart: SetupPart {
    let name: String
    var title: String { name }
    let version = 1
    let log: OrderLog
    func export() async throws(SetupError) -> Data { Data("{}".utf8) }
    func summary(of content: Data) throws(SetupError) -> [SetupItem] { [] }
    func items() async -> [SetupItem] { [] }
    func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        log.add(name)
        return SetupImportReport()
    }
}

/// What already is on the device and differs from the file: the owner's choice, kept by default.
extension SetupExchangeTests {
    /// A device with the sender's account under its id, and a password changed since.
    func deviceWithAnotherPassword(than original: Device) throws -> Device {
        let device = try Device()
        for var account in try original.store.accounts() {
            account.displayName = "Chosen here"
            account.signature = "Signed here"
            try device.store.save(account)
            try device.secrets.setPassword(Secret("chosen here"), for: account.id)
        }
        return device
    }

    @Test func replacingTakesOnlyTheSecret() async throws {
        let passphrase = try Passphrase.generate()
        let original = try sender()
        let file = try await original.exchange().makeFile(passphrase: passphrase)
        let device = try deviceWithAnotherPassword(than: original)
        let before = try device.store.accounts()

        let preview = try await device.exchange().preview(file, passphrase: passphrase)
        // The signature written here differs too, and is its own question.
        #expect(preview.differences.map(\.id) == ["password:pat@example.org", "signature:pat@example.org"])
        let difference = try #require(preview.differences.first)
        let report = await device.exchange().restore(preview, replacing: [difference])

        #expect(report.replaced == [SetupItem(kind: .account, label: "pat@example.org")])
        #expect(report.changedAnything)
        let after = try device.store.accounts()
        #expect(try after.map(encoded) == before.map(encoded))
        let account = try #require(after.first)
        #expect(try device.secrets.password(for: account.id)?.reveal() == "hunter2")
    }

    /// The default: restoring without a choice leaves the device as today.
    @Test func keepingChangesNothing() async throws {
        let passphrase = try Passphrase.generate()
        let original = try sender()
        let file = try await original.exchange().makeFile(passphrase: passphrase)
        let device = try deviceWithAnotherPassword(than: original)
        let before = try device.store.accounts()

        let preview = try await device.exchange().preview(file, passphrase: passphrase)
        let report = await device.exchange().restore(preview, replacing: [])

        #expect(report.replaced.isEmpty)
        let kept = SetupSkip(item: SetupItem(kind: .account, label: "pat@example.org"), reason: .alreadyHere)
        #expect(report.skipped.contains(kept))
        #expect(try device.store.accounts().map(encoded) == before.map(encoded))
        let account = try #require(before.first)
        #expect(try device.secrets.password(for: account.id)?.reveal() == "chosen here")
    }

    @Test func aFileRestoredTwiceHasNoDifferences() async throws {
        let passphrase = try Passphrase.generate()
        let file = try await sender().exchange().makeFile(passphrase: passphrase)
        let device = try Device()

        _ = await device.exchange().restore(try await device.exchange().preview(file, passphrase: passphrase))
        let again = try await device.exchange().preview(file, passphrase: passphrase)

        #expect(again.differences.isEmpty)
    }

    /// An OAuth account's refresh token rotates on renewal between the two restores: still none.
    @Test func aFileRestoredTwiceHasNoDifferencesAfterARotatedToken() async throws {
        let passphrase = try Passphrase.generate()
        let original = try sender()
        let oauth = setupAccount("olle@example.org", auth: .oauth, provider: cloud)
        try original.store.save(oauth)
        try original.secrets.setRefreshToken(Secret("refresh-1"), for: oauth.id)
        let file = try await original.exchange().makeFile(passphrase: passphrase)
        let device = try Device()

        _ = await device.exchange().restore(try await device.exchange().preview(file, passphrase: passphrase))
        #expect(try device.secrets.refreshToken(for: oauth.id)?.reveal() == "refresh-1")
        try device.secrets.setRefreshToken(Secret("refresh-2"), for: oauth.id)
        let again = try await device.exchange().preview(file, passphrase: passphrase)

        #expect(again.differences.isEmpty)
    }
}
