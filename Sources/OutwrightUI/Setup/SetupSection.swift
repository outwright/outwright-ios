// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An encrypted setup file (`Outwright setup <date>.outwright-setup`).
    static let outwrightSetup = UTType(exportedAs: "app.outwright.setup", conformingTo: .data)
}

/// Settings › Back up and move: the setup as an encrypted file, to keep or to open on another device,
/// sent straight to another device or brought from one, and restoring a file. Settings presents the
/// file picker and the restore, so they outlive the row.
struct SetupSection: View {
    let app: AppModel
    @Binding var isPicking: Bool

    var body: some View {
        Section {
            if !app.accounts.isEmpty {
                NavigationLink {
                    ExportSetupView(app: app, purpose: .backup)
                } label: {
                    ModuleLabel("Back up", systemImage: Icons.backUp)
                }
                .accessibilityIdentifier("settings.backUp")
                NavigationLink {
                    SendSetupView(app: app)
                } label: {
                    ModuleLabel("Move to another device", systemImage: Icons.moveDevice)
                }
                .accessibilityIdentifier("settings.moveDevice")
            }
            NavigationLink {
                ReceiveSetupView(app: app)
            } label: {
                ModuleLabel("Bring my setup from another device", systemImage: Icons.bringSetup)
            }
            .accessibilityIdentifier("settings.bringSetup")
            Button {
                isPicking = true
            } label: {
                ModuleLabel("Restore from a file", systemImage: Icons.restore)
            }
            .accessibilityIdentifier("settings.restoreSetup")
        } header: {
            Text(ui: "Back up and move")
        } footer: {
            Text(
                ui: """
                    Your accounts, keys and settings, encrypted, straight to your other device or in a file. They go \
                    only where you send them.
                    """)
        }
    }
}

/// The first run's question, before the address is typed: bring the setup straight from another device
/// instead of adding an account.
struct FirstRunBringSection: View {
    let app: AppModel

    var body: some View {
        Section {
            NavigationLink {
                ReceiveSetupView(app: app, closesFirstRun: true)
            } label: {
                Text(ui: "Bring my setup from another device")
            }
            .accessibilityIdentifier("addAccount.bringSetup")
        } header: {
            Text(ui: "Already use Outwright on another device?")
                .textCase(nil)
        } footer: {
            Text(ui: "Shows a code to scan with Outwright on the device that has your accounts.")
        }
    }
}

/// The first run's other way to bring a setup: from a file, whose restore opens once the first-run
/// screen has closed for it.
struct FirstRunRestoreSection: View {
    let app: AppModel
    @State private var isPicking = false

    var body: some View {
        Section {
            Button { isPicking = true } label: { Text(ui: "Import from a file") }
                .accessibilityIdentifier("addAccount.restore")
        } footer: {
            Text(ui: "A file made with Back up or Send as a file instead.")
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.outwrightSetup, .data]) { result in
            guard case .success(let url) = result else { return }
            app.openSetupFile(url)
        }
    }
}

/// A row of a list of setup items: one item by its label, or the items of a kind shown as a count.
enum SetupRow: Equatable, Hashable {
    case item(SetupItem)
    case counted(SetupItem.Kind, Int)

    /// The kinds shown as a count: contacts' keys run into the thousands.
    static let countedKinds: Set<SetupItem.Kind> = [.contactKey]

    /// The items in order, those of a counted kind as one row where the first of them was.
    static func rows(_ items: [SetupItem]) -> [SetupRow] {
        rows(items.map { ($0, 0) }).map(\.row)
    }

    /// What was not added, those of a counted kind as one row for each reason.
    static func skipRows(_ skips: [SetupSkip]) -> [SetupSkipRow] {
        rows(skips.map { ($0.item, $0.reason) }).map { SetupSkipRow(row: $0.row, reason: $0.group) }
    }

    /// Items with a group each; a counted kind makes one row per group.
    private static func rows<Group: Hashable>(
        _ items: [(item: SetupItem, group: Group)]
    ) -> [(row: SetupRow, group: Group)] {
        var rows: [(row: SetupRow, group: Group)] = []
        var position: [Pair<Group>: Int] = [:]
        for (item, group) in items {
            guard countedKinds.contains(item.kind) else {
                rows.append((.item(item), group))
                continue
            }
            let key = Pair(kind: item.kind, group: group)
            if let index = position[key], rows.indices.contains(index),
                case .counted(let kind, let count) = rows[index].row {
                rows[index].row = .counted(kind, count + 1)
            } else {
                position[key] = rows.count
                rows.append((.counted(item.kind, 1), group))
            }
        }
        return rows
    }

    private struct Pair<Group: Hashable>: Hashable {
        var kind: SetupItem.Kind
        var group: Group
    }

    /// A part's title as the owner reads it: an empty one had nothing fit to show.
    static func partName(_ title: String) -> String {
        title.isEmpty ? L10n.string("Unnamed part") : title
    }

    /// A count of the items of a counted kind.
    static func counted(_ kind: SetupItem.Kind, _ count: Int) -> Text? {
        switch kind {
        case .contactKey: Text(ui: "\(count) contacts' keys")
        default: nil
        }
    }

    /// The row as the owner reads it.
    var text: Text {
        switch self {
        case .item(let item): Text(verbatim: item.kind == .part ? Self.partName(item.label) : item.label)
        case .counted(let kind, let count): Self.counted(kind, count) ?? Text(verbatim: "\(count)")
        }
    }
}

/// A row of what was not added, and why.
struct SetupSkipRow: Equatable, Hashable {
    var row: SetupRow
    var reason: SkipReason
}

/// The items of a setup file by kind, one section each. Before a restore, each account has a
/// switch to bring it here or leave it off this device.
struct SetupItemSections: View {
    let items: [SetupItem]
    /// The restore the accounts' switches belong to; nil shows the accounts as plain rows.
    var choosing: SetupModel?

    var body: some View {
        ForEach(Self.kinds, id: \.self) { kind in
            let ofKind = items.filter { $0.kind == kind }
            if !ofKind.isEmpty {
                Section {
                    ForEach(Array(SetupRow.rows(ofKind).enumerated()), id: \.offset) { _, row in
                        if let choosing, case .item(let item) = row, item.kind == .account {
                            AccountSwitch(model: choosing, address: item.label)
                        } else {
                            row.text
                        }
                    }
                } header: {
                    SetupItemSections.title(kind)
                }
            }
        }
    }

    static let kinds: [SetupItem.Kind] = [
        .account, .calendar, .ownKey, .contactKey, .addressSettings, .part
    ]

    static func title(_ kind: SetupItem.Kind) -> Text {
        switch kind {
        case .account: Text(ui: "Accounts")
        case .calendar: Text(ui: "Subscribed calendars")
        case .ownKey: Text(ui: "Your OpenPGP keys")
        case .contactKey: Text(ui: "Contacts' OpenPGP keys")
        case .addressSettings: Text(ui: "OpenPGP settings")
        case .part: Text(ui: "Other")
        }
    }
}

/// An account in what comes: on, it is brought here; off, it is left off this device (and an
/// account already here is left as it is), remembered for the next time.
private struct AccountSwitch: View {
    let model: SetupModel
    let address: String

    var body: some View {
        Toggle(isOn: Binding(get: { model.isIncluded(address) }, set: { model.setIncluded(address, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: address)
                if !model.isIncluded(address) {
                    Text(ui: "Not on this device")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("setup.include.\(address.lowercased())")
    }
}
