// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSetup
import SwiftUI

#if canImport(UIKit)
    import UIKit
    import UniformTypeIdentifiers
#endif

/// Back up, or move to another device as a file: what goes in, the unlock, then the passphrase and
/// the share sheet. The file is removed when the screen goes.
struct ExportSetupView: View {
    let app: AppModel
    let purpose: SetupPurpose
    @State private var model: SetupModel?
    @State private var made: Made?
    @State private var isWorking = false
    @State private var failed = false
    /// Something in the setup can never go in a file: trying again would end the same.
    @State private var cannotBeMade = false
    @State private var copied = false
    /// The words are hidden whenever the app is not in front, so the app switcher's snapshot never holds them.
    @Environment(\.scenePhase) private var scenePhase
    /// How long a copied passphrase stays on the clipboard.
    static let clipboardLife: Duration = .seconds(120)

    struct Made {
        let url: URL
        let passphrase: Passphrase
    }

    var body: some View {
        Form {
            if let made, let model {
                passphrase(made.passphrase, canCopy: model.canCopyPassphrase)
                Section {
                    ShareLink(item: made.url) {
                        if purpose == .backup {
                            ModuleLabel("Save or send the file", systemImage: Icons.share)
                        } else {
                            ModuleLabel("Send the file", systemImage: Icons.share)
                        }
                    }
                    .accessibilityIdentifier("setup.share")
                } footer: {
                    if purpose == .backup {
                        Text(ui: "Save it in Files or iCloud Drive, or mail it to yourself.")
                    } else {
                        Text(ui: "AirDrop it to your other device, or save it where that device can open it.")
                    }
                }
                SetupItemSections(items: model.exported)
            } else {
                intro
            }
        }
        .navigationTitle(purpose == .backup ? Text(ui: "Back up") : Text(ui: "Move to another device"))
        .inlineNavigationTitle()
        .onAppear {
            guard model == nil else { return }
            let model = app.setupModel()
            self.model = model
            Task { await model.loadItems() }
        }
    }

    private var intro: some View {
        Group {
            Section {
                Label {
                    if purpose == .backup {
                        Text(ui: "What is listed below goes into one encrypted file to keep somewhere safe.")
                    } else {
                        Text(
                            ui: """
                                What is listed below goes into one encrypted file to open with Outwright on your \
                                other device.
                                """)
                    }
                } icon: {
                    Image(systemName: Icons.locked)
                }
            } footer: {
                Text(ui: "You unlock first. Then six words are shown: the file opens only with them.")
            }
            if let model { SetupItemSections(items: model.items) }
            Section {
                Button {
                    Task { await make() }
                } label: {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(ui: "Making the file…")
                        }
                    } else {
                        Text(ui: "Make the file")
                    }
                }
                .disabled(isWorking || model == nil || cannotBeMade)
                .accessibilityIdentifier("setup.make")
            } footer: {
                if cannotBeMade {
                    Text(ui: "The file can't be made: something in your setup is too large for it, or damaged.")
                        .foregroundStyle(Theme.delete)
                } else if failed {
                    Text(ui: "The file couldn't be made. Try again.").foregroundStyle(Theme.delete)
                }
            }
        }
    }

    /// The six words in pairs, large; the copy button only for a backup.
    private func passphrase(_ passphrase: Passphrase, canCopy: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if scenePhase == .active {
                    ForEach(Array(Self.pairs(passphrase).enumerated()), id: \.offset) { _, pair in
                        Text(verbatim: pair)
                    }
                } else {
                    ForEach(0..<3, id: \.self) { _ in Text(verbatim: "••••• •••••") }
                }
            }
            .font(.title2.weight(.semibold).monospaced())
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setup.passphrase")
            if canCopy {
                Button {
                    copy(passphrase)
                } label: {
                    if copied {
                        ModuleLabel("Copied", systemImage: Icons.confirm)
                    } else {
                        ModuleLabel("Copy", systemImage: Icons.copy)
                    }
                }
                .accessibilityIdentifier("setup.copy")
            }
        } header: {
            Text(ui: "Passphrase")
        } footer: {
            if purpose == .backup {
                Text(
                    ui: """
                        Write it down and keep it apart from the file. It is shown only now, and without it \
                        the file can't be opened.
                        """)
            } else {
                Text(ui: "Type it on your other device when you open the file there. It is shown only now.")
            }
        }
    }

    static func pairs(_ passphrase: Passphrase) -> [String] {
        var pairs: [String] = []
        var first: String?
        for word in passphrase.words {
            if let held = first {
                pairs.append(held + " " + word)
                first = nil
            } else {
                first = word
            }
        }
        if let first { pairs.append(first) }
        return pairs
    }

    private func make() async {
        guard let model, !isWorking else { return }
        isWorking = true
        failed = false
        defer { isWorking = false }
        switch await model.export(purpose: purpose) {
        case .file(let url, let passphrase): made = Made(url: url, passphrase: passphrase)
        case .cancelled: break
        case .failed: failed = true
        case .cannotBeMade: cannotBeMade = true
        }
    }

    /// On this device only, and gone from the clipboard after two minutes.
    private func copy(_ passphrase: Passphrase) {
        #if canImport(UIKit)
            let life = Self.clipboardLife
            let expiry = Date().addingTimeInterval(Double(life.components.seconds))
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: passphrase.display]],
                options: [.localOnly: true, .expirationDate: expiry])
            copied = true
            Task {
                // "Copied" lasts as long as the clipboard keeps the words.
                try? await Task.sleep(for: life)
                copied = false
            }
        #endif
    }
}
