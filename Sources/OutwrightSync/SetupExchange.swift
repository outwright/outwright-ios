// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightSetup

/// What an opened setup file holds, before anything is added: the items of each part this build
/// reads, and the parts it does not.
public struct SetupPreview: Sendable, Equatable {
    public struct PartItems: Sendable, Equatable {
        public var name: String
        public var items: [SetupItem]
    }

    public var bundle: SetupBundle
    /// The parts this build reads, in the order they are restored.
    public var items: [PartItems]
    /// The titles of the parts this build has no reader for, or a newer version than it reads; an
    /// empty one is a part with nothing fit to show, for which the screens show their own word.
    public var notInThisBuild: [String]
    /// The titles of the parts this build reads whose content it could not read: left out, the
    /// others restored all the same.
    public var unreadable: [String] = []
    /// What the file holds that this device already has otherwise, in the order the parts are
    /// restored: each kept as the device has it unless the owner chooses the file's.
    public var differences: [SetupDifference] = []
}

/// A setup file just made, and what it holds.
public struct SetupExport: Sendable {
    public var file: Data
    public var items: [SetupItem]
}

/// Makes a setup file from the build's parts, and restores one: accounts first (the other parts
/// may speak of them), then the rest in name order.
public struct SetupExchange: Sendable {
    let parts: [any SetupPart]
    let device: String
    let parameters: Argon2Parameters

    /// `parameters` are the Argon2 costs a new file is sealed with; a file is opened with its own.
    public init(parts: [any SetupPart], device: String, parameters: Argon2Parameters = .writer) {
        var seen = Set<String>()
        self.parts = parts
            .filter { seen.insert($0.name).inserted }
            .sorted { Self.rank($0) < Self.rank($1) }
        self.device = device
        self.parameters = parameters
    }

    private static func rank(_ part: any SetupPart) -> (Int, String) {
        (part.name == AccountsSetupPart.partName ? 0 : 1, part.name)
    }

    public func makeFile(passphrase: Passphrase) async throws(SetupError) -> Data {
        try await export(passphrase: passphrase).file
    }

    /// What a file made now would carry, read without a secret: shown before the owner unlocks.
    public func items() async -> [SetupItem] {
        var items: [SetupItem] = []
        for part in parts { items += await part.items() }
        return items
    }

    /// The file, and what went into it for the owner to see.
    public func export(passphrase: Passphrase) async throws(SetupError) -> SetupExport {
        let (bundle, items) = try await exportBundle()
        return SetupExport(file: try bundle.sealed(passphrase: passphrase, parameters: parameters), items: items)
    }

    /// What every part holds now, unsealed, and what went into it for the owner to see: a file's
    /// content, or what a direct transfer sends.
    public func exportBundle() async throws(SetupError) -> (bundle: SetupBundle, items: [SetupItem]) {
        var held: [String: SetupBundle.Part] = [:]
        var items: [SetupItem] = []
        for part in parts {
            let content = try await part.export()
            held[part.name] = SetupBundle.Part(version: part.version, title: part.title, content: content)
            items += try part.summary(of: content)
        }
        return (SetupBundle(created: Date(), device: device, parts: held), items)
    }

    /// Opens the file and reads what each part holds, and how it differs from this device;
    /// nothing is added.
    public func preview(_ file: Data, passphrase: Passphrase) async throws(SetupError) -> SetupPreview {
        await preview(try SetupBundle.opened(file, passphrase: passphrase))
    }

    /// Reads what each part of a bundle holds, and how it differs from this device; nothing is
    /// added. A part whose content cannot be read is listed as such, has no differences, and never
    /// stops the others.
    public func preview(_ bundle: SetupBundle) async -> SetupPreview {
        var items: [SetupPreview.PartItems] = []
        var unreadable: [String] = []
        var differences: [SetupDifference] = []
        var known = Set<String>()
        for part in parts {
            guard let held = bundle.parts[part.name], held.version <= part.version else { continue }
            known.insert(part.name)
            do {
                items.append(SetupPreview.PartItems(name: part.name, items: try part.summary(of: held.content)))
            } catch {
                unreadable.append(part.title)
                continue
            }
            // Only the part's own: a part never speaks for another.
            differences += await part.differences(in: held.content).filter { $0.part == part.name }
        }
        let notRead = bundle.parts.keys.filter { !known.contains($0) }.sorted().map { bundle.label(of: $0) ?? "" }
        return SetupPreview(
            bundle: bundle, items: items, notInThisBuild: notRead, unreadable: unreadable, differences: differences)
    }

    /// Adds what the preview holds and this device does not have, part by part. Of what is on the
    /// device otherwise, only the preview's differences in `replacing` are taken from the file;
    /// every other is kept as the device has it.
    public func restore(_ preview: SetupPreview, replacing: Set<SetupDifference> = []) async -> SetupImportReport {
        var report = SetupImportReport()
        let wanted = Set(preview.items.map(\.name))
        let chosen = replacing.intersection(preview.differences)
        for part in parts where wanted.contains(part.name) {
            guard let held = preview.bundle.parts[part.name] else { continue }
            let ids = Set(chosen.filter { $0.part == part.name }.map(\.id))
            report.merge(await part.importContent(held.content, version: held.version, replacing: ids))
        }
        for title in preview.unreadable {
            report.merge(.unreadable(title))
        }
        for title in preview.notInThisBuild {
            report.merge(.notRead(title))
        }
        return report
    }
}
