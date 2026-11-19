// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import LocalAuthentication
public import Observation
public import OutwrightSetup
public import OutwrightSync

/// Proving the owner is at the device (Face ID, Touch ID or the passcode) before secrets are read:
/// the system's, or a stand-in in tests.
public protocol DeviceUnlock: Sendable {
    func unlock(reason: String) async -> Bool
}

/// The device owner's own check, with the passcode when biometrics fail or are not set up.
public struct SystemDeviceUnlock: DeviceUnlock {
    public init() {}

    public func unlock(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A device without a passcode has no lock to prove the owner with: whoever holds it
            // reads everything already.
            return error?.domain == LAErrorDomain && error?.code == LAError.passcodeNotSet.rawValue
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Why a setup file is made: a backup the owner keeps (the passphrase may be copied), or a move to
/// another device (it never touches the clipboard).
public enum SetupPurpose: Sendable, Equatable {
    case backup, move
}

/// How making a setup file ended.
public enum ExportState: Sendable, Equatable {
    /// The file, in a temporary place until the model is dismissed, and its passphrase.
    case file(URL, Passphrase)
    /// The owner did not unlock.
    case cancelled
    /// Something went wrong that may not the next time (the keychain, the disk): worth trying again.
    case failed
    /// Something in the setup can never go in a file (too large, or out of shape): trying again
    /// would end the same.
    case cannotBeMade
}

/// Where restoring a setup file is.
public enum RestoreState: Sendable, Equatable {
    /// What was typed did not open the file.
    public enum EntryProblem: Sendable, Equatable {
        /// Not six words from the list.
        case notTheWords
        /// Six words, but not the ones the file was made with.
        case wrongPassphrase
    }

    case idle
    /// The file is read; its passphrase is asked for.
    case entry(problem: EntryProblem?)
    case opening
    /// What the file holds, before anything is added.
    case preview(SetupPreview)
    case restoring
    case report(SetupImportReport)
    /// The file could not be read, or is not a setup file this build opens.
    case unreadable
}

/// Asking the owner to allow notifications after restored accounts came with their notices on.
public struct SetupNotices: Sendable {
    /// Whether any account notifies of new mail.
    let anyOn: @Sendable () async -> Bool
    /// Asks the owner once; later calls answer as before.
    let ask: @Sendable () async -> Bool

    public init(anyOn: @escaping @Sendable () async -> Bool, ask: @escaping @Sendable () async -> Bool) {
        self.anyOn = anyOn
        self.ask = ask
    }

    public static let none = SetupNotices(anyOn: { false }, ask: { false })
}

/// Asking the owner for access to the phone's Contacts after restored accounts came with saving
/// their contacts to the phone on; refused, it goes off for them.
public struct SetupPhoneContacts: Sendable {
    /// Of the accounts added, those that save their contacts to the phone.
    let saving: @Sendable ([SetupItem]) async -> [SetupItem]
    /// Asks the owner for access once; true when allowed.
    let ask: @Sendable () async -> Bool
    /// Turns saving to the phone off for these accounts; returns those it is off for now. One whose
    /// switch could not be changed stays on, and its next refresh tells the owner Contacts is refused.
    let turnOff: @Sendable ([SetupItem]) async -> [SetupItem]

    public init(
        saving: @escaping @Sendable ([SetupItem]) async -> [SetupItem], ask: @escaping @Sendable () async -> Bool,
        turnOff: @escaping @Sendable ([SetupItem]) async -> [SetupItem]
    ) {
        self.saving = saving
        self.ask = ask
        self.turnOff = turnOff
    }

    public static let none = SetupPhoneContacts(saving: { _ in [] }, ask: { false }, turnOff: { _ in [] })
}

/// Backing up or moving the setup as a file, and restoring one. The file made lives only in the
/// temporary directory and is removed when the model is dismissed; the passphrase is never kept
/// beyond the screen that shows it.
@MainActor @Observable
public final class SetupModel {
    public private(set) var state: RestoreState = .idle
    /// What a file made now would hold, read without a secret (`loadItems`).
    public private(set) var items: [SetupItem] = []
    /// What the file just made holds.
    public private(set) var exported: [SetupItem] = []
    /// The accounts (addresses, lower-cased) the owner leaves off this device; for a new preview,
    /// those left off the last time.
    public internal(set) var leavingOff: Set<String> = []
    /// The difference the owner is being asked about, after the button, one at a time.
    public internal(set) var question: SetupDifference?
    /// What the owner answered so far: the differences to take from the other side.
    @ObservationIgnored var replacing: Set<SetupDifference> = []
    /// Resumed with the owner's answer to `question`, or nil when the questions end unanswered.
    @ObservationIgnored var answering: CheckedContinuation<Bool?, Never>?
    @ObservationIgnored private var purpose: SetupPurpose?

    @ObservationIgnored private let exchange: SetupExchange
    @ObservationIgnored private let unlock: any DeviceUnlock
    @ObservationIgnored private let notices: SetupNotices
    @ObservationIgnored private let phoneContacts: SetupPhoneContacts
    /// This model's own folder for the file it makes.
    @ObservationIgnored let exportFolder: URL
    /// The file being restored, read once so a wrong passphrase can be tried again.
    @ObservationIgnored private var file: Data?
    /// Where the file being restored came from.
    @ObservationIgnored private var received: URL?

    public init(
        exchange: SetupExchange, unlock: any DeviceUnlock, notices: SetupNotices = .none,
        phoneContacts: SetupPhoneContacts = .none
    ) {
        self.exchange = exchange
        self.unlock = unlock
        self.notices = notices
        self.phoneContacts = phoneContacts
        exportFolder = Self.temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A model that goes without being dismissed (its screen was closed) takes its file with it.
    deinit {
        try? FileManager.default.removeItem(at: exportFolder)
    }

    /// Where every setup model makes its files.
    static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OutwrightSetup", isDirectory: true)
    }

    /// Removes files a model made and could not remove (the app was closed while one was shown).
    /// Called at launch, before any model is made. Documents/Inbox is left alone here: on a cold
    /// launch iOS puts the file the app opens for there before its URL arrives (`sweepHandedOver`).
    public static func removeLeftovers() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    /// Removes the setup files iOS handed over that no restore will open, keeping those still to be
    /// restored.
    static func sweepHandedOver(inbox: URL?, keeping: [URL]) {
        guard let inbox,
            let handed = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        else { return }
        let kept = Set(keeping.map { $0.resolvingSymlinksInPath().path })
        for file in handed where file.pathExtension == "outwright-setup" {
            guard !kept.contains(file.resolvingSymlinksInPath().path) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Reads what a file made now would hold, for the screen before the unlock.
    public func loadItems() async {
        items = await exchange.items()
    }

    /// A backup may copy its passphrase; a move keeps it off the clipboard.
    public var canCopyPassphrase: Bool { purpose == .backup }

    /// Unlocks, then makes the file with a new passphrase.
    public func export(purpose: SetupPurpose) async -> ExportState {
        removeExport()
        let reason = switch purpose {
        case .backup: L10n.string("Unlock to back up your accounts and keys.")
        case .move: L10n.string("Unlock to move your accounts and keys.")
        }
        guard await unlock.unlock(reason: reason) else { return .cancelled }
        guard let passphrase = try? Passphrase.generate() else { return .failed }
        let exchange = exchange
        // Detached: sealing is seconds of Argon2, never on the main actor.
        let result = await Task.detached { () -> Result<SetupExport, SetupError> in
            do throws(SetupError) {
                return .success(try await exchange.export(passphrase: passphrase))
            } catch {
                return .failure(error)
            }
        }.value
        let made: SetupExport
        switch result {
        case .success(let file): made = file
        case .failure(.tooLarge), .failure(.malformed): return .cannotBeMade
        case .failure: return .failed
        }
        let url = exportFolder.appendingPathComponent(Self.fileName(on: Date()))
        do {
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            try made.file.write(to: url, options: Self.writing)
        } catch {
            removeExport()
            return .failed
        }
        self.purpose = purpose
        exported = made.items
        return .file(url, passphrase)
    }

    /// Encrypted at rest on the phone while it is locked, unless the share sheet has it open.
    private static var writing: Data.WritingOptions {
        #if os(iOS)
            [.withoutOverwriting, .completeFileProtectionUnlessOpen]
        #else
            [.withoutOverwriting]
        #endif
    }

    static func fileName(on date: Date) -> String {
        L10n.string("Outwright setup") + " " + date.formatted(.iso8601.year().month().day()) + ".outwright-setup"
    }

    /// Reads a setup file to restore; its passphrase is asked for next.
    public func open(_ url: URL) {
        endQuestions()
        file = nil
        received = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = Self.read(url) else {
            state = .unreadable
            return
        }
        file = data
        state = .entry(problem: nil)
    }

    /// At most what a setup file can be; nothing for an empty or larger one.
    static func read(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: SymmetricMessage.maximumSize + 1),
            !data.isEmpty, data.count <= SymmetricMessage.maximumSize
        else { return nil }
        return data
    }

    /// Opens the file with what the owner typed: the preview, or the entry again with what was wrong.
    public func enter(_ typed: String) async {
        guard case .entry = state, let file else { return }
        guard let passphrase = try? Passphrase(typed: typed) else {
            state = .entry(problem: .notTheWords)
            return
        }
        state = .opening
        let exchange = exchange
        let opened = await Task.detached { () async -> Result<SetupPreview, SetupError> in
            do throws(SetupError) { return .success(try await exchange.preview(file, passphrase: passphrase)) } catch {
                return .failure(error)
            }
        }.value
        switch opened {
        case .success(let preview): show(preview)
        case .failure(.wrongPassphrase): state = .entry(problem: .wrongPassphrase)
        case .failure: state = .unreadable
        }
    }

    /// Shows a preview with nothing answered yet, and the accounts left off last time off again.
    private func show(_ preview: SetupPreview) {
        endQuestions()
        replacing = []
        leavingOff = preview.leftOff
        state = .preview(preview)
    }

    /// Asks the differences, then adds what the preview holds, then shows the report. Added
    /// accounts that save their contacts to the phone ask for access to its Contacts once (refused,
    /// that goes off for them); restored accounts that notify ask the owner once for permission to.
    public func restore() async {
        guard await askQuestions(), let report = await add() else { return }
        state = .report(await askForPhoneContacts(report))
        await askForNotices()
    }

    /// Adds what the preview holds, with the owner's choices, and returns the report, before any
    /// owner prompt; nil when there was no preview. The state stays `.restoring`.
    private func add() async -> SetupImportReport? {
        guard case .preview(let preview) = state else { return nil }
        state = .restoring
        let exchange = exchange
        let (replacing, leavingOff) = (replacing, leavingOff)
        let report = await Task.detached {
            await exchange.restore(preview, replacing: replacing, leavingOff: leavingOff)
        }.value
        file = nil
        self.replacing = []
        return report
    }

    /// Added accounts that save their contacts to the phone ask for access to its Contacts once;
    /// refused, saving goes off for them and the report says so.
    private func askForPhoneContacts(_ report: SetupImportReport) async -> SetupImportReport {
        var report = report
        let added = report.added.filter { $0.kind == .account }
        let saving = added.isEmpty ? [] : await phoneContacts.saving(added)
        if !saving.isEmpty, !(await phoneContacts.ask()) {
            // Only those really turned off: the report never says off for a switch still on.
            report.phoneContactsOff = await phoneContacts.turnOff(saving)
        }
        return report
    }

    /// After a restore's report: restored accounts that notify ask the owner once for permission to.
    public func askForNotices() async {
        guard case .report(let report) = state, report.added.contains(where: { $0.kind == .account }),
            await notices.anyOn()
        else { return }
        _ = await notices.ask()
    }

    /// The preview of a bundle straight from another device, as a file's; nothing restored yet.
    public func previewReceived(_ bundle: SetupBundle) async -> SetupPreview {
        let exchange = exchange
        let preview = await Task.detached { await exchange.preview(bundle) }.value
        show(preview)
        return preview
    }

    /// Restores the received preview with the owner's answers (`askQuestions` first) and returns
    /// what was added (nil without one), before any ask: the other device hears `done` before a
    /// prompt is up.
    public func restoreReceived() async -> SetupImportReport? {
        guard let report = await add() else { return nil }
        state = .report(report)
        return report
    }

    /// After `restoreReceived`, once the other device was told: the Contacts ask, as a file's
    /// restore makes it, and the report with what it turned off (handed to `updated` before the
    /// next ask), then the notifications ask.
    public func askAfterReceived(_ updated: @MainActor (SetupImportReport) -> Void) async {
        guard case .report(let report) = state else { return }
        let asked = await askForPhoneContacts(report)
        if case .report = state { state = .report(asked) }
        updated(asked)
        await askForNotices()
    }

    /// The flow is over: the file made is removed, and so is the copy iOS handed over of one opened.
    public func dismissed() {
        endQuestions()
        removeExport()
        file = nil
        if let received { Self.discardHandedOver(received) }
        received = nil
    }

    private func removeExport() {
        try? FileManager.default.removeItem(at: exportFolder)
        exported = []
        purpose = nil
    }
}
