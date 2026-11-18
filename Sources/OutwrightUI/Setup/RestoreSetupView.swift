// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI

/// Restoring a setup file: its six words, then what it holds, then what was added. The model is
/// made when the sheet appears and dismissed when it goes.
struct RestoreSetupView: View {
    let app: AppModel
    let url: URL
    @State private var model: SetupModel?

    var body: some View {
        NavigationStack {
            if let model {
                RestoreSetupFlow(app: app, model: model)
            } else {
                ProgressView()
            }
        }
        .interactiveDismissDisabled(model?.state == .restoring)
        .onAppear {
            guard model == nil else { return }
            let model = app.setupModel()
            model.open(url)
            self.model = model
        }
        .onDisappear { model?.dismissed() }
    }
}

/// The screens of a restore, one for each step.
private struct RestoreSetupFlow: View {
    let app: AppModel
    let model: SetupModel
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle(Text(ui: "Restore"))
            .inlineNavigationTitle()
            .toolbar { toolbar }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .opening:
            working(Text(ui: "Opening the file…"))
        case .entry(let problem):
            entry(problem)
        case .preview(let preview):
            previewForm(preview)
        case .restoring:
            working(Text(ui: "Restoring…"))
        case .report(let report):
            SetupReportForm(report: report, source: .file)
        case .unreadable:
            ContentUnavailableView {
                Label { Text(ui: "Can't open this file") } icon: { Image(systemName: Icons.warning) }
            } description: {
                Text(ui: "It isn't a setup file this version of Outwright reads, or it is damaged.")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if isOver {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: { Text(ui: "Done") }
                    .accessibilityIdentifier("restore.done")
            }
        } else if model.state != .restoring {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text(ui: "Cancel") }
            }
        }
    }

    /// Nothing is left to do but close.
    private var isOver: Bool {
        switch model.state {
        case .report, .unreadable: true
        default: false
        }
    }

    private func working(_ text: Text) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            text.foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The passphrase

    private func entry(_ problem: RestoreState.EntryProblem?) -> some View {
        Form {
            Section {
                TextField(text: $typed) { Text(ui: "Six words") }
                    .passphraseEntry()
                    .onSubmit { open() }
                    .accessibilityIdentifier("restore.passphrase")
                let suggestions = SetupModel.suggestions(for: typed)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { word in
                                Button {
                                    typed = SetupModel.completing(typed, with: word)
                                } label: {
                                    Text(verbatim: word)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } header: {
                Text(ui: "Passphrase")
            } footer: {
                switch problem {
                case .notTheWords:
                    Text(ui: "Type the six words shown when the file was made.").foregroundStyle(Theme.delete)
                case .wrongPassphrase:
                    Text(ui: "These words don't open the file. Check them and try again.")
                        .foregroundStyle(Theme.delete)
                case nil:
                    Text(ui: "The six words shown on the device the file was made on.")
                }
            }
            Section {
                Button { open() } label: { Text(ui: "Open") }
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("restore.open")
            }
        }
    }

    private func open() {
        let words = typed
        Task { await model.enter(words) }
    }

    // MARK: What the file holds

    private func previewForm(_ preview: SetupPreview) -> some View {
        Form {
            made(preview)
            SetupDifferencesSection(model: model, differences: preview.differences, source: .file)
            SetupItemSections(items: preview.items.flatMap(\.items))
            if !preview.notInThisBuild.isEmpty {
                Section {
                    ForEach(Array(preview.notInThisBuild.enumerated()), id: \.offset) {
                        Text(verbatim: SetupRow.partName($0.element))
                    }
                } header: {
                    Text(ui: "Not in this version")
                } footer: {
                    Text(ui: "This version of Outwright doesn't read these parts of the file; they are left out.")
                }
            }
            if !preview.unreadable.isEmpty {
                Section {
                    ForEach(Array(preview.unreadable.enumerated()), id: \.offset) { Text(verbatim: $0.element) }
                } header: {
                    Text(ui: "Can't be read")
                } footer: {
                    Text(ui: "These parts of the file are damaged; they are left out and the rest is restored.")
                }
            }
            Section {
                Button {
                    Task { await restore() }
                } label: {
                    Text(ui: "Restore")
                }
                .accessibilityIdentifier("restore.restore")
            }
        }
    }

    /// Where and when the file was made, and what happens to what the device has.
    private func made(_ preview: SetupPreview) -> some View {
        Section {
            LabeledContent {
                Text(verbatim: preview.bundle.shownDevice)
            } label: {
                Text(ui: "Made on")
            }
            LabeledContent {
                Text(preview.bundle.created, format: .dateTime.day().month().year().hour().minute())
            } label: {
                Text(ui: "Date")
            }
        } footer: {
            if preview.differences.isEmpty {
                Text(
                    ui: """
                        What you already have on this device is left as it is. A password, key or calendar \
                        address missing from it is filled in.
                        """)
            } else {
                Text(
                    ui: """
                        What you already have on this device is left as it is, unless you choose the file's \
                        below. A password, key or calendar address missing from it is filled in.
                        """)
            }
        }
    }

    private func restore() async {
        await model.restore()
        if case .report(let report) = model.state, report.changedAnything {
            await app.restoredFromSetup()
        }
    }
}

/// What a restore added, filled in and left out, and what the owner still does: after a file and
/// after a setup received from another device.
struct SetupReportForm: View {
    /// Where what was restored came from: a file, or another device (by its name and when the setup was made
    /// there, when known).
    enum Source {
        case file
        case device(SetupOrigin?)
    }

    let report: SetupImportReport
    let source: Source

    var body: some View {
        Form {
            if case .device(let origin?) = source {
                Section {
                    LabeledContent {
                        Text(verbatim: SetupDevice.name(origin.device))
                    } label: {
                        Text(ui: "From")
                    }
                    LabeledContent {
                        Text(origin.created, format: .dateTime.day().month().year().hour().minute())
                    } label: {
                        Text(ui: "Date")
                    }
                }
            }
            let added = report.added.filter { !report.signInAgain.contains($0) }
            if added.isEmpty && report.signInAgain.isEmpty && report.restored.isEmpty && report.replaced.isEmpty {
                Section {
                    Text(ui: "Nothing was added.")
                }
            } else if !added.isEmpty {
                Section {
                    rows(added)
                } header: {
                    Text(ui: "Added")
                }
            }
            if !report.restored.isEmpty {
                Section {
                    rows(report.restored)
                } header: {
                    Text(ui: "Filled in")
                } footer: {
                    switch source {
                    case .file:
                        Text(
                            ui: """
                                These were on this device without their password, key or address; it came from the \
                                file.
                                """)
                    case .device:
                        Text(
                            ui: """
                                These were on this device without their password, key or address; it came from your \
                                other device.
                                """)
                    }
                }
            }
            if !report.replaced.isEmpty {
                Section {
                    rows(report.replaced)
                } header: {
                    switch source {
                    case .file: Text(ui: "Replaced from the file")
                    case .device: Text(ui: "Replaced from your other device")
                    }
                }
            }
            toDo(report)
            if !report.skipped.isEmpty {
                skipped(report.skipped)
            }
        }
    }

    /// What the owner still does for the accounts restored.
    @ViewBuilder private func toDo(_ report: SetupImportReport) -> some View {
        if !report.signInAgain.isEmpty {
            Section {
                rows(report.signInAgain)
            } header: {
                Text(ui: "Sign in again")
            } footer: {
                Text(ui: "Their sign-in couldn't come along. Sign in from the account in Settings.")
            }
        }
        if !report.notificationsOff.isEmpty {
            Section {
                rows(report.notificationsOff)
            } header: {
                Text(ui: "Notifications off")
            } footer: {
                Text(ui: "Their notifications couldn't be turned on. Turn them on in Settings.")
            }
        }
        if !report.phoneContactsOff.isEmpty {
            Section {
                rows(report.phoneContactsOff)
            } header: {
                Text(ui: "Contacts not saved to iPhone")
            } footer: {
                Text(
                    ui: """
                        Outwright isn't allowed to use Contacts, so Save contacts to iPhone is off for these. \
                        Turn it on in the account's settings.
                        """)
            }
        }
    }

    private func rows(_ items: [SetupItem]) -> some View {
        ForEach(Array(SetupRow.rows(items).enumerated()), id: \.offset) { _, row in row.text }
    }

    private func skipped(_ skips: [SetupSkip]) -> some View {
        Section {
            ForEach(Array(SetupRow.skipRows(skips).enumerated()), id: \.offset) { _, skip in
                LabeledContent {
                    Self.reason(skip.reason)
                } label: {
                    skip.row.text
                }
            }
        } header: {
            Text(ui: "Not added")
        }
    }

    static func reason(_ reason: SkipReason) -> Text {
        switch reason {
        case .alreadyHere: Text(ui: "Already here")
        case .notInThisBuild: Text(ui: "Not in this version")
        case .failed: Text(ui: "Couldn't be added")
        }
    }
}

extension View {
    /// The keyboard for typing the six words: no capitals, corrections or suggestions of its own.
    fileprivate func passphraseEntry() -> some View {
        #if os(iOS)
            self.textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
        #else
            self.autocorrectionDisabled()
        #endif
    }
}
