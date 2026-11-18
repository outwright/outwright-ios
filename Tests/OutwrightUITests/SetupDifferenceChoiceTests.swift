// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

/// What the device already has that differs from the file: the owner chooses, and keeping is the
/// default.
@MainActor @Suite struct SetupDifferenceChoiceTests {
    /// A device with one password account, through the real accounts part.
    @MainActor struct Device {
        let store: MailStore
        let secrets = InMemorySecretStore()
        let account: Account

        init(password: String) throws {
            store = try MailStore(path: nil)
            let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
            account = Account(
                id: AccountID(raw: UUID()), displayName: "Pat", email: "pat@example.org", colorIndex: 0,
                imap: endpoint, smtp: endpoint, user: "pat@example.org", signature: "", sortOrder: 0)
            try store.save(account)
            try secrets.setPassword(Secret(password), for: account.id)
        }

        func exchange() -> SetupExchange {
            let providers = ProviderSet([OwnServerProvider()])
            let part = AccountsSetupPart(store: store, secrets: secrets, providers: providers)
            let quick = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)
            return SetupExchange(parts: [part], device: "Test phone", parameters: quick)
        }

        func model() -> SetupModel {
            SetupModel(exchange: exchange(), unlock: SetupModelTests.FakeUnlock(answer: true))
        }

        var password: String? { try? secrets.password(for: account.id)?.reveal() }
    }

    static let difference = SetupDifference(
        kind: .accountSecret, part: "accounts", label: "pat@example.org", id: "pat@example.org")

    /// A file opened to its preview, on the device it is restored to.
    struct Previewing {
        let model: SetupModel
        let device: Device
        let file: URL
        let passphrase: Passphrase
    }

    /// A file from a device whose password is "hunter2", opened on one that has "chosen here".
    func previewing() async throws -> Previewing {
        let passphrase = try Passphrase.generate()
        let data = try await Device(password: "hunter2").exchange().makeFile(passphrase: passphrase)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("setup.outwright-setup")
        try data.write(to: url)
        let device = try Device(password: "chosen here")
        let model = device.model()
        model.open(url)
        await model.enter(passphrase.display)
        return Previewing(model: model, device: device, file: url, passphrase: passphrase)
    }

    @Test func choicesStartAtKeep() async throws {
        let shown = try await previewing()
        let (model, device) = (shown.model, shown.device)
        defer { SetupModelTests.remove(shown.file) }
        guard case .preview(let preview) = model.state else {
            Issue.record("no preview: \(model.state)")
            return
        }
        #expect(preview.differences == [Self.difference])
        #expect(model.replacing.isEmpty)

        await model.restore()
        #expect(device.password == "chosen here")
    }

    @Test func choosingTheFilesPasswordReplacesIt() async throws {
        let shown = try await previewing()
        let (model, device) = (shown.model, shown.device)
        defer { SetupModelTests.remove(shown.file) }
        model.choose(Self.difference, fromFile: true)
        #expect(model.replacing == [Self.difference])

        await model.restore()
        #expect(device.password == "hunter2")
        guard case .report(let report) = model.state else {
            Issue.record("no report: \(model.state)")
            return
        }
        #expect(report.replaced == [SetupItem(kind: .account, label: "pat@example.org")])
    }

    @Test func choosingKeepAgainUndoesTheChoice() async throws {
        let shown = try await previewing()
        let (model, device) = (shown.model, shown.device)
        defer { SetupModelTests.remove(shown.file) }
        model.choose(Self.difference, fromFile: true)
        model.choose(Self.difference, fromFile: false)
        #expect(model.replacing.isEmpty)

        await model.restore()
        #expect(device.password == "chosen here")
    }

    @Test func aNewPreviewForgetsTheChoices() async throws {
        let shown = try await previewing()
        let model = shown.model
        defer { SetupModelTests.remove(shown.file) }
        model.choose(Self.difference, fromFile: true)

        model.open(shown.file)
        await model.enter(shown.passphrase.display)
        #expect(model.replacing.isEmpty)
        await model.restore()
        #expect(shown.device.password == "chosen here")
    }
}
