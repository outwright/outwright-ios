// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI

/// Already on this device: what the device has that differs from what is restored, each with the
/// owner's choice between the device's (the default) and the one restored. Nothing shows when
/// nothing differs. No secret is ever shown, only that one differs.
struct SetupDifferencesSection: View {
    let model: SetupModel
    let differences: [SetupDifference]
    /// Where what is restored comes from, which the choice names.
    let source: SetupReportForm.Source

    var body: some View {
        if !differences.isEmpty {
            Section {
                ForEach(Array(differences.enumerated()), id: \.offset) { index, difference in
                    VStack(alignment: .leading, spacing: 10) {
                        Self.text(difference)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("restore.difference.\(index)")
                        VStack(alignment: .leading, spacing: 10) {
                            option(useTheirs, fromFile: true, for: difference)
                            option(Text(ui: "Keep this device's"), fromFile: false, for: difference)
                        }
                        .padding(.leading, 16)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("restore.differenceChoice.\(index)")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(ui: "Already on this device")
            } footer: {
                footer
            }
        }
    }

    /// One of the two choices, checked when chosen. Its own row's tap only: several buttons share
    /// the difference's row. Read out with the difference it is for.
    private func option(_ title: Text, fromFile: Bool, for difference: SetupDifference) -> some View {
        let chosen = model.replacing.contains(difference) == fromFile
        return Button {
            model.choose(difference, fromFile: fromFile)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                title
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: Icons.confirm).foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("\(Self.text(difference)), \(title)"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var useTheirs: Text {
        switch source {
        case .file: Text(ui: "Use the file's")
        case .device: Text(ui: "Use the other device's")
        }
    }

    @ViewBuilder private var footer: some View {
        let keys = differences.contains { $0.kind == .ownKey }
        switch (source, keys) {
        case (.file, false):
            Text(ui: "These differ from the file. Unless you choose the file's, this device's stay as they are.")
        case (.file, true):
            Text(
                ui: """
                    These differ from the file. Unless you choose the file's, this device's stay as they are. A key \
                    from the file is added either way, so mail encrypted to it still opens.
                    """)
        case (.device, false):
            Text(
                ui: """
                    These differ from your other device. Unless you choose the other device's, this device's stay \
                    as they are.
                    """)
        case (.device, true):
            Text(
                ui: """
                    These differ from your other device. Unless you choose the other device's, this device's stay \
                    as they are. A key from your other device is added either way, so mail encrypted to it still \
                    opens.
                    """)
        }
    }

    /// The difference as the owner reads it: what differs, never the secret.
    static func text(_ difference: SetupDifference) -> Text {
        switch difference.kind {
        case .accountSecret: Text(ui: "\(difference.label): the password or sign-in differs")
        case .ownKey: Text(ui: "\(difference.label): another key is your current one")
        case .settings: Text(ui: "Settings you changed on this device")
        }
    }
}
