// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightSetup
import OutwrightStore
import OutwrightSync
import Synchronization
import Testing

@testable import OutwrightUI

@MainActor @Suite struct SetupModelTests {
    /// Small Argon2 parameters, so a test seals in milliseconds.
    static let quick = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)

    struct FakeUnlock: DeviceUnlock {
        let answer: Bool
        func unlock(reason: String) async -> Bool { answer }
    }

    /// A part holding two accounts, which it adds on import.
    struct TwoAccounts: SetupPart {
        let name = "accounts"
        let title = "Accounts"
        let version = 1
        static let items = [
            SetupItem(kind: .account, label: "pat@example.org"), SetupItem(kind: .account, label: "lee@example.org")
        ]
        func export() async throws(SetupError) -> Data { Data("{}".utf8) }
        func summary(of content: Data) throws(SetupError) -> [SetupItem] { Self.items }
        func items() async -> [SetupItem] { Self.items }
        func importContent(_ content: Data, version: Int) async -> SetupImportReport {
            SetupImportReport(added: Self.items)
        }
    }

    /// Counts the times the owner was asked to allow notifications.
    final class Asked: Sendable {
        private let count = Mutex(0)
        var times: Int { count.withLock { $0 } }
        func ask() -> Bool {
            count.withLock { $0 += 1 }
            return true
        }
    }

    static func exchange() -> SetupExchange {
        SetupExchange(parts: [TwoAccounts()], device: "Test phone", parameters: quick)
    }

    static func model(unlocks: Bool = true, notices: SetupNotices = .none) -> SetupModel {
        SetupModel(exchange: exchange(), unlock: FakeUnlock(answer: unlocks), notices: notices)
    }

    /// A setup file in a folder of its own, and the passphrase it opens with.
    static func file() async throws -> (URL, Passphrase) {
        let passphrase = try Passphrase.generate()
        let data = try await exchange().makeFile(passphrase: passphrase)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("setup.outwright-setup")
        try data.write(to: url)
        return (url, passphrase)
    }

    /// Removes a fixture's folder.
    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func whatGoesInIsShownBeforeUnlocking() async {
        let model = Self.model(unlocks: false)
        await model.loadItems()
        #expect(model.items == TwoAccounts.items)
    }

    @Test func exportNeedsUnlock() async throws {
        let model = Self.model(unlocks: false)
        #expect(await model.export(purpose: .backup) == .cancelled)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: model.exportFolder.path)) ?? []
        #expect(written.isEmpty)
    }

    @Test func exportWritesTheFileToATemporaryPlace() async throws {
        let model = Self.model()
        guard case .file(let url, let passphrase) = await model.export(purpose: .move) else {
            Issue.record("no file")
            return
        }
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(url.standardizedFileURL.path.hasPrefix(temporary))
        let preview = try await Self.exchange().preview(try Data(contentsOf: url), passphrase: passphrase)
        #expect(preview.items.flatMap(\.items) == TwoAccounts.items)
        #expect(model.exported == TwoAccounts.items)

        model.dismissed()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func backupOffersCopyMoveDoesNot() async {
        let backup = Self.model()
        _ = await backup.export(purpose: .backup)
        #expect(backup.canCopyPassphrase)
        backup.dismissed()

        let move = Self.model()
        _ = await move.export(purpose: .move)
        #expect(!move.canCopyPassphrase)
        move.dismissed()
    }

    @Test func wrongPassphraseLetsTheOwnerTryAgain() async throws {
        let (url, passphrase) = try await Self.file()
        defer { Self.remove(url) }
        let model = Self.model()
        model.open(url)
        #expect(model.state == .entry(problem: nil))

        await model.enter("not six words")
        #expect(model.state == .entry(problem: .notTheWords))
        await model.enter(try Passphrase.generate().display)
        #expect(model.state == .entry(problem: .wrongPassphrase))
        // The file is still there to try again with.
        await model.enter(passphrase.words.joined(separator: " ").uppercased())
        guard case .preview = model.state else {
            Issue.record("no preview: \(model.state)")
            return
        }
        model.dismissed()
    }

    @Test func restoreShowsPreviewThenReport() async throws {
        let (url, passphrase) = try await Self.file()
        defer { Self.remove(url) }
        let model = Self.model()
        model.open(url)
        await model.enter(passphrase.display)
        guard case .preview(let preview) = model.state else {
            Issue.record("no preview: \(model.state)")
            return
        }
        #expect(preview.items.flatMap(\.items) == TwoAccounts.items)
        #expect(preview.bundle.device == "Test phone")

        await model.restore()
        #expect(model.state == .report(SetupImportReport(added: TwoAccounts.items)))
    }

    @Test func aFileThatCannotBeReadSaysSo() {
        let model = Self.model()
        model.open(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(model.state == .unreadable)
    }

    @Test func restoredAccountsThatNotifyAskForPermissionOnce() async throws {
        let asked = Asked()
        let (url, passphrase) = try await Self.file()
        defer { Self.remove(url) }
        let model = Self.model(notices: SetupNotices(anyOn: { true }, ask: { asked.ask() }))
        model.open(url)
        await model.enter(passphrase.display)
        await model.restore()
        #expect(asked.times == 1)

        let quiet = Asked()
        let silent = Self.model(notices: SetupNotices(anyOn: { false }, ask: { quiet.ask() }))
        silent.open(url)
        await silent.enter(passphrase.display)
        await silent.restore()
        #expect(quiet.times == 0)
    }

    /// A part whose export fails as given.
    struct FailingPart: SetupPart {
        let name = "failing"
        let title = "Failing"
        let version = 1
        let error: SetupError
        func export() async throws(SetupError) -> Data { throw error }
        func summary(of content: Data) throws(SetupError) -> [SetupItem] { [] }
        func items() async -> [SetupItem] { [] }
        func importContent(_ content: Data, version: Int) async -> SetupImportReport { SetupImportReport() }
    }

    /// Something in the setup that can never go in the file is told apart from a failure worth
    /// trying again.
    @Test func aFileThatCanNeverBeMadeIsToldApartFromOneToTryAgain() async {
        func export(failing error: SetupError) async -> ExportState {
            let exchange = SetupExchange(
                parts: [TwoAccounts(), FailingPart(error: error)], device: "Test phone", parameters: Self.quick)
            let model = SetupModel(exchange: exchange, unlock: FakeUnlock(answer: true))
            defer { model.dismissed() }
            return await model.export(purpose: .backup)
        }
        #expect(await export(failing: .tooLarge) == .cannotBeMade)
        #expect(await export(failing: .malformed) == .cannotBeMade)
        #expect(await export(failing: .unavailable) == .failed)
    }

    /// Records what the phone's Contacts were asked and turned off.
    final class PhoneContacts: Sendable {
        let allows: Bool
        /// Accounts whose switch cannot be changed.
        let stuck: [String]
        private let held = Mutex<(asked: Int, off: [SetupItem])>((0, []))
        var asked: Int { held.withLock { $0.asked } }
        var off: [SetupItem] { held.withLock { $0.off } }

        init(allows: Bool, stuck: [String] = []) {
            self.allows = allows
            self.stuck = stuck
        }

        func setup(saving: [String]) -> SetupPhoneContacts {
            SetupPhoneContacts(
                saving: { added in added.filter { saving.contains($0.label) } },
                ask: {
                    self.held.withLock { $0.asked += 1 }
                    return self.allows
                },
                turnOff: { items in
                    let off = items.filter { !self.stuck.contains($0.label) }
                    self.held.withLock { $0.off += off }
                    return off
                })
        }
    }

    func restored(with contacts: SetupPhoneContacts) async throws -> SetupModel {
        let (url, passphrase) = try await Self.file()
        defer { Self.remove(url) }
        let model = SetupModel(exchange: Self.exchange(), unlock: FakeUnlock(answer: true), phoneContacts: contacts)
        model.open(url)
        await model.enter(passphrase.display)
        await model.restore()
        return model
    }

    /// Added accounts that save their contacts to the phone ask for access once; refused, the switch
    /// goes off for them and the report says so.
    @Test func restoredAccountsThatSaveToThePhoneAskForAccess() async throws {
        let pat = SetupItem(kind: .account, label: "pat@example.org")
        let refused = PhoneContacts(allows: false)
        let model = try await restored(with: refused.setup(saving: ["pat@example.org"]))
        #expect(refused.asked == 1)
        #expect(refused.off == [pat])
        #expect(model.state == .report(SetupImportReport(added: TwoAccounts.items, phoneContactsOff: [pat])))

        let allowed = PhoneContacts(allows: true)
        let kept = try await restored(with: allowed.setup(saving: ["pat@example.org"]))
        #expect(allowed.asked == 1)
        #expect(allowed.off.isEmpty)
        #expect(kept.state == .report(SetupImportReport(added: TwoAccounts.items)))

        // A switch that could not be turned off is not reported as off.
        let stuck = PhoneContacts(allows: false, stuck: ["pat@example.org"])
        let still = try await restored(with: stuck.setup(saving: ["pat@example.org"]))
        #expect(still.state == .report(SetupImportReport(added: TwoAccounts.items)))

        let none = PhoneContacts(allows: false)
        _ = try await restored(with: none.setup(saving: []))
        #expect(none.asked == 0)
        #expect(none.off.isEmpty)
    }

    @Test func droppingTheModelDeletesTheExport() async throws {
        func exported() async -> URL? {
            let model = Self.model()
            guard case .file(let url, _) = await model.export(purpose: .backup) else { return nil }
            #expect(FileManager.default.fileExists(atPath: url.path))
            return url
        }
        let url = try #require(await exported())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFileLargerThanASetupFileCanBeIsUnreadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("large.outwright-setup")
        try Data(count: SymmetricMessage.maximumSize + 1).write(to: url)
        let model = Self.model()
        model.open(url)
        #expect(model.state == .unreadable)
    }

    @Test func suggestionsCompleteTheWordBeingTyped() {
        let suggestions = SetupModel.suggestions(for: "abacus abd")
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.hasPrefix("abd") })
        #expect(SetupModel.suggestions(for: "abacus ").isEmpty)
    }
}

@MainActor @Suite struct SetupFileAtLaunchTests {
    static func app() throws -> AppModel {
        let store = try MailStore(path: nil)
        return AppModel(store: store, sync: SyncCoordinator(store: store, secrets: InMemorySecretStore()))
    }

    static let file = FileManager.default.temporaryDirectory.appendingPathComponent("absent.outwright-setup")

    @Test func aFileOpenedAtFirstLaunchHoldsTheFirstRunScreenBack() throws {
        let app = try Self.app()
        app.openSetupFile(Self.file)
        app.appeared()
        #expect(!app.isAddingAccount)
        #expect(app.setupFileToOpen != nil)

        // The restore closed with no account: the first-run screen opens as usual.
        app.setupFileToOpen = nil
        app.setupFileClosed()
        #expect(app.isAddingAccount)
    }

    @Test func aFileWaitingForASheetHoldsTheFirstRunScreenBackToo() throws {
        let app = try Self.app()
        app.isShowingHelp = true
        app.openSetupFile(Self.file)
        app.appeared()
        #expect(!app.isAddingAccount)
        app.isShowingHelp = false
        app.openPending()
        #expect(app.setupFileToOpen != nil)
    }

    @Test func aFileOpenedWhileBringingWaitsForTheBringToClose() throws {
        let app = try Self.app()
        app.isBringingSetup = true
        app.openSetupFile(Self.file)
        #expect(app.setupFileToOpen == nil)
        app.isBringingSetup = false
        app.openPending()
        #expect(app.setupFileToOpen != nil)
    }

    @Test func aFileOpenedWhileTheFirstRunRestoresWaitsForIt() throws {
        let app = try Self.app()
        app.isAddingAccount = true
        app.firstRunHeld = true
        app.openSetupFile(Self.file)
        #expect(app.isAddingAccount, "the first run stays while its restore runs or reports")
        #expect(app.setupFileToOpen == nil)

        // Left without an account (Done after nothing came, or Back): the first run closes for the file.
        app.firstRunHeld = false
        #expect(!app.isAddingAccount)
        app.openPending()
        #expect(app.setupFileToOpen != nil)
    }

    /// A folder standing in for Documents/Inbox, with a setup file iOS handed over in it.
    static func inbox(with name: String) async throws -> (inbox: URL, file: URL, passphrase: Passphrase) {
        let (made, passphrase) = try await SetupModelTests.file()
        let inbox = made.deletingLastPathComponent()
        let file = inbox.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: file)
        return (inbox, file, passphrase)
    }

    @Test func aFileOpenedAtColdLaunchSurvivesLaunchCleanupAndRestores() async throws {
        let (inbox, file, passphrase) = try await Self.inbox(with: "opened.outwright-setup")
        defer { try? FileManager.default.removeItem(at: inbox) }
        // Launch cleanup runs before iOS hands the URL to the app.
        SetupModel.removeLeftovers()
        let app = try Self.app()
        app.openSetupFile(file)
        app.appeared()
        #expect(FileManager.default.fileExists(atPath: file.path))

        let model = SetupModelTests.model()
        model.open(try #require(app.setupFileToOpen).url)
        await model.enter(passphrase.display)
        await model.restore()
        #expect(model.state == .report(SetupImportReport(added: SetupModelTests.TwoAccounts.items)))
    }

    @Test func staleHandedOverFilesAreSweptWhenARestoreCloses() async throws {
        let (inbox, waiting, _) = try await Self.inbox(with: "waiting.outwright-setup")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let stale = inbox.appendingPathComponent("stale.outwright-setup")
        let other = inbox.appendingPathComponent("other.pdf")
        try Data([1]).write(to: stale)
        try Data([2]).write(to: other)
        let app = try Self.app()
        app.isShowingHelp = true
        app.openSetupFile(waiting)

        app.setupFileClosed(inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: waiting.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func goingToTheBackgroundSweepsAllButTheFileShowing() async throws {
        let (inbox, showing, _) = try await Self.inbox(with: "showing.outwright-setup")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let stale = inbox.appendingPathComponent("stale.outwright-setup")
        try Data([1]).write(to: stale)
        let app = try Self.app()
        app.openSetupFile(showing)
        #expect(app.setupFileToOpen != nil)

        app.sweepSetupFiles(inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: showing.path))
    }
}
