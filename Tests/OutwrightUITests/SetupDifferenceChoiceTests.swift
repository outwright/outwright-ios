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

/// What the device already has that differs from the file: after the button, each difference is
/// asked in turn, and only then is anything added.
@MainActor @Suite struct SetupDifferenceChoiceTests {
    /// A device with one password account, through the real accounts part.
    @MainActor struct Device {
        let store: MailStore
        let secrets = InMemorySecretStore()
        let account: Account

        init(password: String, signature: String = "") throws {
            store = try MailStore(path: nil)
            let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
            account = Account(
                id: AccountID(raw: UUID()), displayName: "Pat", email: "pat@example.org", colorIndex: 0,
                imap: endpoint, smtp: endpoint, user: "pat@example.org", signature: signature, sortOrder: 0)
            try store.save(account)
            try secrets.setPassword(Secret(password), for: account.id)
        }

        func exchange() -> SetupExchange {
            let providers = ProviderSet([OwnServerProvider()])
            let part = AccountsSetupPart(store: store, secrets: secrets, providers: providers)
            let quick = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)
            return SetupExchange(parts: [part], device: "Test phone", parameters: quick, secrets: secrets)
        }

        func model() -> SetupModel {
            SetupModel(exchange: exchange(), unlock: SetupModelTests.FakeUnlock(answer: true))
        }

        var password: String? { try? secrets.password(for: account.id)?.reveal() }
        var signature: String? { try? store.accounts().first?.signature }
    }

    /// A file opened to its preview, on the device it is restored to.
    struct Previewing {
        let model: SetupModel
        let device: Device
        let file: URL
        let passphrase: Passphrase
    }

    /// A file from a device with `there`, opened on one with `here`.
    func previewing(
        there: (password: String, signature: String) = ("hunter2", ""),
        here: (password: String, signature: String) = ("chosen here", "")
    ) async throws -> Previewing {
        let passphrase = try Passphrase.generate()
        let data = try await Device(password: there.password, signature: there.signature).exchange()
            .makeFile(passphrase: passphrase)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("setup.outwright-setup")
        try data.write(to: url)
        let device = try Device(password: here.password, signature: here.signature)
        let model = device.model()
        model.open(url)
        await model.enter(passphrase.display)
        return Previewing(model: model, device: device, file: url, passphrase: passphrase)
    }

    /// Waits for the model to ask, and returns what it asks.
    func asked(_ model: SetupModel) async -> SetupDifference? {
        _ = await eventually { model.question != nil }
        return model.question
    }

    @Test func buttonWithNoDifferenceRestoresAtOnce() async throws {
        let shown = try await previewing(there: ("hunter2", ""), here: ("hunter2", ""))
        defer { SetupModelTests.remove(shown.file) }

        await shown.model.restore()

        #expect(shown.model.question == nil)
        guard case .report = shown.model.state else {
            Issue.record("no report: \(shown.model.state)")
            return
        }
    }

    @Test func differencesAreAskedOneAtATimeAfterTheButton() async throws {
        let shown = try await previewing(there: ("hunter2", "Pat at work"), here: ("chosen here", "Pat on the phone"))
        let (model, device) = (shown.model, shown.device)
        defer { SetupModelTests.remove(shown.file) }
        // Nothing is asked before the button.
        #expect(model.question == nil)

        let restoring = Task { await model.restore() }
        let first = await asked(model)
        #expect(first?.kind == .accountSecret)
        #expect(device.password == "chosen here")
        model.answer(useOther: true)

        _ = await eventually { model.question?.kind == .signature }
        #expect(model.question?.kind == .signature)
        model.answer(useOther: false)
        await restoring.value

        #expect(model.question == nil)
        #expect(device.password == "hunter2")
        #expect(device.signature == "Pat on the phone")
        guard case .report(let report) = model.state else {
            Issue.record("no report: \(model.state)")
            return
        }
        #expect(report.replaced == [SetupItem(kind: .account, label: "pat@example.org")])
    }

    @Test func accountSwitchedOffIsLeftOffAndNotAsked() async throws {
        let shown = try await previewing()
        let (model, device) = (shown.model, shown.device)
        defer { SetupModelTests.remove(shown.file) }
        #expect(model.isIncluded("pat@example.org"))

        model.setIncluded("Pat@example.org", false)
        #expect(!model.isIncluded("pat@example.org"))
        await model.restore()

        #expect(model.question == nil)
        #expect(device.password == "chosen here")
        guard case .report(let report) = model.state else {
            Issue.record("no report: \(model.state)")
            return
        }
        #expect(report.skipped.map(\.reason) == [.leftOff])
    }

    @Test func aSecondRunAsksNothingAfterKeeping() async throws {
        let shown = try await previewing()
        defer { SetupModelTests.remove(shown.file) }
        let restoring = Task { await shown.model.restore() }
        _ = await asked(shown.model)
        shown.model.answer(useOther: false)
        await restoring.value

        shown.model.open(shown.file)
        await shown.model.enter(shown.passphrase.display)
        await shown.model.restore()

        #expect(shown.model.question == nil)
        #expect(shown.device.password == "chosen here")
    }

    @Test func aNewPreviewForgetsAnUnfinishedQuestion() async throws {
        let shown = try await previewing()
        let model = shown.model
        defer { SetupModelTests.remove(shown.file) }
        let restoring = Task { await model.restore() }
        _ = await asked(model)

        model.open(shown.file)
        await restoring.value
        #expect(model.question == nil)
        #expect(shown.device.password == "chosen here")
    }

    /// The question goes as soon as it is answered, so the alert never shows it again for a moment.
    @Test func answeringClearsTheQuestionAtOnce() async throws {
        let shown = try await previewing()
        defer { SetupModelTests.remove(shown.file) }
        let restoring = Task { await shown.model.restore() }
        _ = await asked(shown.model)

        shown.model.answer(useOther: false)
        #expect(shown.model.question == nil)
        await restoring.value
    }
}
