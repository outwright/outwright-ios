// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightStore
import OutwrightSetup
import OutwrightSync
import Testing

@testable import OutwrightUI

@Suite struct SettingsSetupPartTests {
    /// A defaults of its own, empty.
    static func defaults() -> UserDefaults {
        let name = "outwright.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func settingsMoveBetweenDefaults() async throws {
        let from = Self.defaults()
        let shared = Self.defaults()
        let account = UUID().uuidString
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        let quiet = try JSONEncoder().encode(DoNotDisturb(until: until, preset: .oneHour))
        from.set(false, forKey: SettingsKeys.focusedInbox)
        from.set(false, forKey: SettingsKeys.backgroundRefresh)
        from.set("flag", forKey: SettingsKeys.swipeLeading)
        from.set("archive", forKey: SettingsKeys.swipeTrailing)
        from.set(account, forKey: SettingsKeys.defaultAccount)
        from.set("month", forKey: SettingsKeys.calendarMode)
        from.set("workWeek", forKey: SettingsKeys.calendarWeekMode)
        shared.set(false, forKey: "badge.focusedOnly")
        shared.set(quiet, forKey: SettingsKeys.doNotDisturb)

        let content = try await SettingsSetupPart(defaults: from, shared: shared).export()
        let to = Self.defaults()
        let toShared = Self.defaults()
        let known = UUID(uuidString: account) ?? UUID()
        let part = SettingsSetupPart(defaults: to, shared: toShared, accounts: { [known] })
        let report = await part.importContent(content, version: part.version)

        #expect(report.skipped.isEmpty)
        #expect(to.object(forKey: SettingsKeys.focusedInbox) as? Bool == false)
        #expect(to.object(forKey: SettingsKeys.backgroundRefresh) as? Bool == false)
        #expect(to.string(forKey: SettingsKeys.swipeLeading) == "flag")
        #expect(to.string(forKey: SettingsKeys.swipeTrailing) == "archive")
        #expect(to.string(forKey: SettingsKeys.defaultAccount) == account)
        #expect(to.string(forKey: SettingsKeys.calendarMode) == "month")
        #expect(to.string(forKey: SettingsKeys.calendarWeekMode) == "workWeek")
        #expect(toShared.object(forKey: "badge.focusedOnly") as? Bool == false)
        // A running pause is state, not a choice: it stays behind.
        #expect(toShared.data(forKey: SettingsKeys.doNotDisturb) == nil)
        #expect(!(try part.summary(of: content)).isEmpty)
    }

    @Test func storeLocalIdsStayBehind() async throws {
        let defaults = Self.defaults()
        defaults.set([Int64(3), 4], forKey: SettingsKeys.shownCalendars)
        defaults.set(["3": 0xFF0000], forKey: SettingsKeys.calendarColors)
        defaults.set("some search", forKey: "unrelatedKey")
        defaults.set(false, forKey: SettingsKeys.focusedInbox)

        let content = try await SettingsSetupPart(defaults: defaults).export()
        let text = try #require(String(bytes: content, encoding: .utf8))

        #expect(!text.contains(SettingsKeys.shownCalendars))
        #expect(!text.contains(SettingsKeys.calendarColors))
        #expect(!text.contains("unrelatedKey"))

        // A bundle that names them anyway writes nothing.
        let hostile = Data(#"{"values":{"shownCalendars":"x","calendarColors":"y","unrelatedKey":"z"}}"#.utf8)
        let receiver = Self.defaults()
        let part = SettingsSetupPart(defaults: receiver)
        _ = await part.importContent(hostile, version: part.version)
        #expect(receiver.object(forKey: SettingsKeys.shownCalendars) == nil)
        #expect(receiver.object(forKey: SettingsKeys.calendarColors) == nil)
        #expect(receiver.object(forKey: "unrelatedKey") == nil)
    }

    /// What the device has set is its own choice: only settings it never set are taken.
    @Test func aSettingTheDeviceHasSetIsLeftAsItIs() async throws {
        let from = Self.defaults()
        from.set(false, forKey: SettingsKeys.focusedInbox)
        from.set("flag", forKey: SettingsKeys.swipeLeading)
        from.set("archive", forKey: SettingsKeys.swipeTrailing)
        let content = try await SettingsSetupPart(defaults: from).export()

        let to = Self.defaults()
        to.set(true, forKey: SettingsKeys.focusedInbox)
        to.set("delete", forKey: SettingsKeys.swipeTrailing)
        let part = SettingsSetupPart(defaults: to)
        let report = await part.importContent(content, version: part.version)

        #expect(to.object(forKey: SettingsKeys.focusedInbox) as? Bool == true)
        #expect(to.string(forKey: SettingsKeys.swipeTrailing) == "delete")
        #expect(to.string(forKey: SettingsKeys.swipeLeading) == "flag")
        #expect(report.added.count == 1)
        #expect(report.skipped.count == 2)
        #expect(report.skipped.allSatisfy { $0.reason == .alreadyHere })
    }

    /// Whether the default signature was filled in once is this device's own record, not a choice.
    @Test func theSignatureMarkerStaysBehind() async throws {
        let from = Self.defaults()
        from.set(true, forKey: "defaultSignatureFilled")
        let text = try #require(String(bytes: try await SettingsSetupPart(defaults: from).export(), encoding: .utf8))
        #expect(!text.contains("defaultSignatureFilled"))

        let to = Self.defaults()
        let part = SettingsSetupPart(defaults: to)
        let report = await part.importContent(Data(#"{"values":{"defaultSignatureFilled":true}}"#.utf8), version: 1)
        #expect(to.object(forKey: "defaultSignatureFilled") == nil)
        #expect(report == SetupImportReport())
    }

    @Test func aValueOfTheWrongTypeIsSkippedNeverWritten() async throws {
        let content = Data(
            #"{"values":{"focusedInbox":"yes","swipeLeading":true,"defaultAccount":"nope","badge.focusedOnly":false}}"#
                .utf8)
        let defaults = Self.defaults()
        let shared = Self.defaults()
        let part = SettingsSetupPart(defaults: defaults, shared: shared)
        let report = await part.importContent(content, version: part.version)

        #expect(defaults.object(forKey: SettingsKeys.focusedInbox) == nil)
        #expect(defaults.object(forKey: SettingsKeys.swipeLeading) == nil)
        #expect(defaults.object(forKey: SettingsKeys.defaultAccount) == nil)
        #expect(shared.object(forKey: "badge.focusedOnly") as? Bool == false)
        #expect(report.skipped.count == 3)
        #expect(report.added.count == 1)
    }

    @Test func aWordThatIsNotOneOfTheSettingsOwnIsSkipped() async throws {
        let content = Data(
            #"{"values":{"swipeLeading":"explode","calendarMode":"month","calendarWeekMode":"fortnight"}}"#.utf8)
        let defaults = Self.defaults()
        let part = SettingsSetupPart(defaults: defaults)
        let report = await part.importContent(content, version: part.version)
        #expect(defaults.object(forKey: SettingsKeys.swipeLeading) == nil)
        #expect(defaults.object(forKey: SettingsKeys.calendarWeekMode) == nil)
        #expect(defaults.string(forKey: SettingsKeys.calendarMode) == "month")
        #expect(report.skipped.count == 2)
    }

    @Test func theDefaultAccountMovesOnlyToAnAccountTheDeviceHas() async throws {
        let id = UUID()
        let content = Data(#"{"values":{"defaultAccount":"\#(id.uuidString.lowercased())"}}"#.utf8)

        // Not on the device: the device's own default stays, and the report says nothing of it.
        let without = Self.defaults()
        let missing = SettingsSetupPart(defaults: without)
        let report = await missing.importContent(content, version: 1)
        #expect(without.object(forKey: SettingsKeys.defaultAccount) == nil)
        #expect(report == SetupImportReport())

        let with = Self.defaults()
        let present = SettingsSetupPart(defaults: with, accounts: { [id] })
        _ = await present.importContent(content, version: 1)
        #expect(with.string(forKey: SettingsKeys.defaultAccount) == id.uuidString)
    }

    @Test func aNewerPartIsNotRead() async throws {
        let defaults = Self.defaults()
        let part = SettingsSetupPart(defaults: defaults)
        let newer = Data(#"{"values":{"focusedInbox":false}}"#.utf8)
        let report = await part.importContent(newer, version: part.version + 1)
        #expect(report.skipped.map(\.reason) == [.notInThisBuild])
        #expect(defaults.object(forKey: SettingsKeys.focusedInbox) == nil)
    }

    /// The part's content comes from an opened file: arbitrary bytes and arbitrary JSON are read
    /// without a trap, and only known keys with their own type are ever written.
    @Test func arbitraryContentIsReadWithoutATrap() async throws {
        let from = Self.defaults()
        from.set(false, forKey: SettingsKeys.focusedInbox)
        from.set("flag", forKey: SettingsKeys.swipeLeading)
        let valid = try await SettingsSetupPart(defaults: from).export()
        var random = SystemRandomNumberGenerator()
        let defaults = Self.defaults()
        let shared = Self.defaults()
        let part = SettingsSetupPart(defaults: defaults, shared: shared)
        for round in 0..<300 {
            var bytes: [UInt8]
            if round.isMultiple(of: 2) {
                let count = Int.random(in: 0...512, using: &random)
                bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            } else {
                bytes = [UInt8](valid)
                for _ in 0..<Int.random(in: 1...8, using: &random) {
                    let position = Int.random(in: 0..<bytes.count, using: &random)
                    bytes[position] = UInt8.random(in: 0...255, using: &random)
                }
            }
            _ = try? part.summary(of: Data(bytes))
            _ = await part.importContent(Data(bytes), version: part.version)
        }
        for key in [SettingsKeys.focusedInbox, SettingsKeys.backgroundRefresh] {
            if let value = defaults.object(forKey: key) { #expect(value is Bool) }
        }
        #expect(defaults.object(forKey: SettingsKeys.shownCalendars) == nil)
    }
}

extension SettingsSetupPartTests {
    @Test func theSettingsListedAreTheOnesTheFileCarries() async throws {
        let defaults = Self.defaults()
        let shared = Self.defaults()
        defaults.set(false, forKey: SettingsKeys.focusedInbox)
        defaults.set("flag", forKey: SettingsKeys.swipeLeading)
        let part = SettingsSetupPart(defaults: defaults, shared: shared)
        let listed = await part.items()
        #expect(listed.count == 2)
        #expect(listed == (try part.summary(of: await part.export())))
        #expect(await SettingsSetupPart(defaults: Self.defaults(), shared: Self.defaults()).items().isEmpty)
    }
}

/// Settings the device has set to other values than the file's: one choice for all of them.
extension SettingsSetupPartTests {
    @Test func settingsThatDifferAreOneDifference() async throws {
        let from = Self.defaults()
        from.set(false, forKey: SettingsKeys.focusedInbox)
        from.set("flag", forKey: SettingsKeys.swipeLeading)
        from.set("month", forKey: SettingsKeys.calendarMode)
        let content = try await SettingsSetupPart(defaults: from, shared: Self.defaults()).export()
        let here = Self.defaults()
        here.set(true, forKey: SettingsKeys.focusedInbox)
        here.set("flag", forKey: SettingsKeys.swipeLeading)
        let part = SettingsSetupPart(defaults: here, shared: Self.defaults())

        let differences = await part.differences(in: content)
        #expect(differences == [SetupDifference(kind: .settings, part: "settings", label: part.title, id: "settings")])

        let report = await part.importContent(content, version: part.version, replacing: ["settings"])
        #expect(here.object(forKey: SettingsKeys.focusedInbox) as? Bool == false)
        #expect(here.string(forKey: SettingsKeys.swipeLeading) == "flag")
        #expect(here.string(forKey: SettingsKeys.calendarMode) == "month")
        #expect(report.replaced == [SetupItem(kind: .settings, label: SettingsKeys.focusedInbox)])
        #expect(report.added == [SetupItem(kind: .settings, label: SettingsKeys.calendarMode)])
        #expect(await part.differences(in: content).isEmpty)
    }

    @Test func settingsKeptStayAsTheDeviceHasThem() async throws {
        let content = Data(#"{"values":{"focusedInbox":false}}"#.utf8)
        let here = Self.defaults()
        here.set(true, forKey: SettingsKeys.focusedInbox)
        let part = SettingsSetupPart(defaults: here, shared: Self.defaults())

        let report = await part.importContent(content, version: part.version, replacing: [])

        #expect(here.object(forKey: SettingsKeys.focusedInbox) as? Bool == true)
        #expect(report.replaced.isEmpty)
        #expect(report.skipped.map(\.reason) == [.alreadyHere])
    }

    @Test func settingsTheDeviceHasNotSetAreNoDifference() async throws {
        let content = Data(#"{"values":{"focusedInbox":false}}"#.utf8)
        let part = SettingsSetupPart(defaults: Self.defaults(), shared: Self.defaults())
        #expect(await part.differences(in: content).isEmpty)
    }
}

@MainActor @Suite struct SetupExchangeAppTests {
    struct Extra: SetupPart {
        let name = "extra"
        let title = "Extra"
        let version = 1
        func export() async throws(SetupError) -> Data { Data("{}".utf8) }
        func summary(of content: Data) throws(SetupError) -> [SetupItem] { [] }
        func items() async -> [SetupItem] { [] }
        func importContent(_ content: Data, version: Int) async -> SetupImportReport { SetupImportReport() }
    }

    @Test func theExchangeHoldsTheOpenPartsAndTheModulesOwn() async throws {
        let store = try MailStore(path: nil)
        let app = AppModel(store: store, sync: SyncCoordinator(store: store, secrets: InMemorySecretStore()))
        app.modules.setupParts = [Extra()]
        let passphrase = try Passphrase.generate()
        let quick = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)
        let file = try await app.setupExchange(parameters: quick).makeFile(passphrase: passphrase)
        let preview = try await app.setupExchange(parameters: quick).preview(file, passphrase: passphrase)
        #expect(Set(preview.items.map(\.name)) == ["accounts", "subscriptions", "settings", "extra"])
    }

    /// The app finds the added accounts that save to the phone, and turns that off for them.
    @Test func theAppTurnsSavingToThePhoneOffForTheAccountsAsked() async throws {
        let store = try MailStore(path: nil)
        let app = AppModel(store: store, sync: SyncCoordinator(store: store, secrets: InMemorySecretStore()))
        var saving = Account(
            id: AccountID(), displayName: "Pat", email: "pat@example.org", colorIndex: 1,
            imap: MailEndpoint(host: "imap.example.org", port: 993, security: "tls"),
            smtp: MailEndpoint(host: "smtp.example.org", port: 465, security: "tls"),
            user: "pat@example.org", signature: "", sortOrder: 0)
        saving.savesContactsToPhone = true
        var other = saving
        other.id = AccountID()
        other.email = "lee@example.org"
        other.savesContactsToPhone = false
        try store.save(saving)
        try store.save(other)
        let contacts = app.phoneContactsForSetup()
        let added = [SetupItem(kind: .account, label: "PAT@example.org"), SetupItem(kind: .account, label: "lee@example.org")]

        let found = await contacts.saving(added)
        #expect(found == [SetupItem(kind: .account, label: "pat@example.org")])
        // An account whose switch cannot be changed stays on, and is not said to be off.
        var stuck = saving
        stuck.id = AccountID()
        stuck.email = "kim@example.org"
        try store.save(stuck)
        try store.refuseChangesToKim()
        let kim = SetupItem(kind: .account, label: "kim@example.org")
        #expect(await contacts.turnOff(found + [kim]) == found)
        #expect(try store.accounts().filter(\.savesContactsToPhone).map(\.email) == ["kim@example.org"])
    }
}
