// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSetup
import OutwrightSync
import SwiftUI

/// Bring my setup from another device: a code for the other device to scan, then the restore of what
/// it sends (asking first when this device has something that differs) and its report. Leaving the screen
/// ends the transfer; once the restore has begun, only Done leaves it.
struct ReceiveSetupView: View {
    let app: AppModel
    /// On the first run, Done closes the first run when accounts came.
    var closesFirstRun = false
    @State private var model: ReceiveSetupModel?
    /// The code is hidden whenever the app is not in front, so the app switcher's snapshot never holds it.
    @Environment(\.scenePhase) private var scenePhase
    /// Whether the app went to the background while the code showed: iOS may have ended its listening meanwhile.
    @State private var wentToBackground = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                SetupWorking(text: nil)
            }
        }
        .navigationTitle(Text(ui: "Bring my setup"))
        .inlineNavigationTitle()
        .navigationBarBackButtonHidden(isRestoring)
        .interactiveDismissDisabled(isRestoring)
        .toolbar { toolbar }
        .keepsDeviceAwake()
        .onAppear {
            guard model == nil else { return }
            let model = app.receiveSetupModel()
            self.model = model
            Task { await model.start() }
        }
        // iOS may end the listening while the app is in the background: back in front, a code still shown is
        // replaced by a new one.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: wentToBackground = true
            case .active where wentToBackground:
                wentToBackground = false
                if let model { Task { await model.cameBackFromBackground() } }
            default: break
            }
        }
        // The session ends with the screen; coming back makes a new model and a new code. A restore under way
        // keeps its model (it can't be left, and only Done closes it).
        .onDisappear {
            guard model?.state != .restoring else { return }
            model?.cancel()
            model = nil
        }
    }

    /// The restore has begun: it can't be left halfway, and its report closes with Done.
    private var isRestoring: Bool {
        switch model?.state {
        case .restoring?, .report?: true
        default: false
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if case .report(let report)? = model?.state {
            ToolbarItem(placement: .confirmationAction) {
                Button { done(report) } label: { Text(ui: "Done") }
                    .accessibilityIdentifier("receive.done")
            }
        }
    }

    private func done(_ report: SetupImportReport) {
        if closesFirstRun, report.added.contains(where: { $0.kind == .account }) {
            app.isAddingAccount = false
        } else {
            dismiss()
        }
    }

    @ViewBuilder private func content(_ model: ReceiveSetupModel) -> some View {
        switch model.state {
        case .starting:
            SetupWorking(text: Text(ui: "Making a code…"))
        case .showing(let code, let expires):
            showing(model, code: code, expires: expires)
        case .waiting:
            SetupWorking(text: Text(ui: "Connected. Confirm on your other device."))
        case .choosing(let preview):
            choosing(model, preview)
        case .restoring:
            SetupWorking(text: Text(ui: "Restoring…"))
        case .report(let report):
            SetupReportForm(report: report, source: .device(model.origin))
        case .failed(let failure):
            failed(model, failure)
        }
    }

    // MARK: The code

    private func showing(_ model: ReceiveSetupModel, code: PairingCode, expires: Date) -> some View {
        Form {
            Section {
                Group {
                    if scenePhase == .active {
                        QRCode(text: code.text)
                    } else {
                        Image(systemName: Icons.codeHidden)
                            .font(.largeTitle)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel(Text(ui: "The code to scan"))
                .accessibilityIdentifier("receive.code")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    remaining(until: expires, now: context.date)
                }
            } header: {
                Text(
                    ui: """
                        On your other device, open Outwright, choose Move to another device in Settings and scan \
                        this code.
                        """)
                    .textCase(nil)
            } footer: {
                Text(ui: "Keep both devices near each other. Nothing is sent until you confirm on the other device.")
            }
        }
    }

    /// The time left, and a new code once it has run out.
    @ViewBuilder private func remaining(until expires: Date, now: Date) -> some View {
        let left = max(0, Int(expires.timeIntervalSince(now).rounded(.up)))
        if left > 0 {
            Text(ui: "Valid for \(Self.minutes(left))")
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .accessibilityIdentifier("receive.expiry")
        } else {
            newCodeButton
        }
    }

    /// Seconds as minutes and seconds, 4:05.
    static func minutes(_ seconds: Int) -> String {
        let (minutes, rest) = seconds.quotientAndRemainder(dividingBy: 60)
        return rest < 10 ? "\(minutes):0\(rest)" : "\(minutes):\(rest)"
    }

    private var newCodeButton: some View {
        Button {
            Task { await model?.newCode() }
        } label: {
            Text(ui: "Show a new code")
        }
        .accessibilityIdentifier("receive.newCode")
    }

    // MARK: What differs

    /// What this device has that differs from what came, with the owner's choice for each, and what comes, while
    /// the other device waits for the answer.
    private func choosing(_ model: ReceiveSetupModel, _ preview: SetupPreview) -> some View {
        Form {
            SetupDifferencesSection(
                model: model.setup, differences: preview.differences, source: .device(model.origin))
            SetupItemSections(items: preview.items.flatMap(\.items))
            Section {
                Button {
                    Task { await model.restoreChosen() }
                } label: {
                    Text(ui: "Restore")
                }
                .accessibilityIdentifier("receive.restore")
            } footer: {
                Text(
                    ui: """
                        Your other device waits up to 5 minutes for your answer. If it stops waiting, nothing is \
                        restored.
                        """)
            }
        }
    }

    // MARK: The end

    private func failed(_ model: ReceiveSetupModel, _ failure: ReceiveSetupModel.Failure) -> some View {
        ContentUnavailableView {
            Label { Self.title(failure) } icon: { Image(systemName: Icons.warning) }
        } description: {
            Self.failure(failure)
        } actions: {
            newCodeButton.buttonStyle(.borderedProminent)
        }
    }

    static func title(_ failure: ReceiveSetupModel.Failure) -> Text {
        failure == .expired ? Text(ui: "The code has expired") : Text(ui: "Nothing was brought over")
    }

    static func failure(_ failure: ReceiveSetupModel.Failure) -> Text {
        switch failure {
        case .expired:
            Text(ui: "No device scanned it in time.")
        case .handshake:
            Text(ui: "A device connected without the code, so it can't be used again.")
        case .spent:
            Text(ui: "A device connected but didn't finish connecting, so the code can't be used again.")
        case .newerVersion:
            Text(ui: "It was sent from a newer version of Outwright. Update Outwright on this device and try again.")
        case .stopped:
            Text(ui: "It was cancelled on the other device.")
        case .lost:
            Text(ui: "The connection was lost. Keep both devices near each other and try again.")
        case .cannotListen:
            Text(
                ui: """
                    Outwright can't reach the local network. If you are asked, allow it (Settings › Privacy & \
                    Security › Local Network).
                    """)
        }
    }
}
