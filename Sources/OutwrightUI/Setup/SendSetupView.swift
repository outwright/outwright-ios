// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI

/// Move to another device: scan the code the other device shows, confirm, unlock and send; or send the
/// setup as a file instead. Leaving the screen ends the transfer.
struct SendSetupView: View {
    let app: AppModel
    @State private var model: SendSetupModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                SetupWorking(text: nil)
            }
        }
        .navigationTitle(Text(ui: "Move to another device"))
        .inlineNavigationTitle()
        .keepsDeviceAwake()
        .onAppear {
            guard model == nil else { return }
            let model = app.sendSetupModel()
            self.model = model
            Task { await model.loadItems() }
        }
        // Sending as a file covers this screen too: the transfer ends then, and the scanner is back after.
        .onDisappear { model?.cancel() }
    }

    @ViewBuilder private func content(_ model: SendSetupModel) -> some View {
        switch model.state {
        // One branch for both, so the scanner (and its camera) stays the same view when a wrong code shows.
        case .scanning, .wrongCode:
            scanner(model, problem: Self.problem(of: model.state))
        case .connecting(let device):
            SetupWorking(text: Text(ui: "Connecting to \(SetupDevice.name(device))…"))
        case .confirm(let device, let items):
            confirm(model, device: device, items: items)
        case .sending:
            SetupWorking(text: Text(ui: "Sending… Keep both devices near each other."))
        case .waitingForReceiver:
            SetupWorking(text: Text(ui: "Waiting for your other device…"))
        case .sent(let device):
            sent(device)
        case .failed(let failure):
            failed(model, failure)
        }
    }

    // MARK: The scanner

    private func scanner(_ model: SendSetupModel, problem: SendSetupModel.Problem?) -> some View {
        Form {
            Section {
                CodeScanner { text in Task { await model.scanned(text) } }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("setup.scanner")
            } header: {
                Text(
                    ui: """
                        On your other device, open Outwright and choose Bring my setup from another device. \
                        Then scan the code it shows.
                        """)
                    .textCase(nil)
            } footer: {
                if let problem {
                    Self.problem(problem).foregroundStyle(Theme.delete)
                }
            }
            SetupItemSections(items: model.items)
            Section {
                NavigationLink {
                    ExportSetupView(app: app, purpose: .move)
                } label: {
                    ModuleLabel("Send as a file instead", systemImage: Icons.sendAsFile)
                }
                .accessibilityIdentifier("setup.sendAsFile")
            }
        }
    }

    static func problem(of state: SendSetupModel.State) -> SendSetupModel.Problem? {
        if case .wrongCode(let problem) = state { problem } else { nil }
    }

    static func problem(_ problem: SendSetupModel.Problem) -> Text {
        switch problem {
        case .notACode:
            Text(ui: "That isn't a code for moving your setup. Scan the code on your other device.")
        case .sendsToo:
            Text(ui: "That device is sending, not receiving. On it, choose Bring my setup from another device.")
        case .newerVersion:
            Text(ui: "That code is from a newer version of Outwright. Update Outwright on this device first.")
        }
    }

    // MARK: Confirming

    private func confirm(_ model: SendSetupModel, device: String, items: [SetupItem]) -> some View {
        Form {
            Section {
                Text(ui: "Send your setup to \(SetupDevice.name(device))?")
                    .font(.headline)
            } footer: {
                Text(ui: "What is listed below goes to that device only, encrypted. You unlock first.")
            }
            SetupItemSections(items: items)
            Section {
                Button {
                    Task { await model.send() }
                } label: {
                    Text(ui: "Send")
                }
                .accessibilityIdentifier("setup.send")
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Text(ui: "Cancel")
                }
                .accessibilityIdentifier("setup.cancelSend")
            }
        }
    }

    // MARK: The end

    private func sent(_ device: String) -> some View {
        ContentUnavailableView {
            Label {
                Text(ui: "Your setup is on \(SetupDevice.name(device))")
            } icon: {
                Image(systemName: Icons.succeeded)
            }
        } description: {
            Text(ui: "Its report shows on that device.")
        } actions: {
            Button { dismiss() } label: { Text(ui: "Done") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("setup.done")
        }
    }

    private func failed(_ model: SendSetupModel, _ failure: SendSetupModel.Failure) -> some View {
        ContentUnavailableView {
            Label { Text(ui: "Not sent") } icon: { Image(systemName: Icons.warning) }
        } description: {
            Self.failure(failure)
        } actions: {
            if failure != .cannotBeMade {
                Button { model.scanAgain() } label: { Text(ui: "Scan again") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("setup.scanAgain")
            }
        }
    }

    static func failure(_ failure: SendSetupModel.Failure) -> Text {
        switch failure {
        case .notFound:
            Text(
                ui: """
                    The other device wasn't found. Keep both devices near each other, with Outwright open on the \
                    code. If you are asked, allow Outwright on the local network (Settings › Privacy & Security › \
                    Local Network).
                    """)
        case .handshake:
            Text(ui: "The other device doesn't hold this code any more. Show a new code on it and scan that.")
        case .stopped:
            Text(ui: "It was cancelled on the other device.")
        case .lost, .timedOut:
            Text(ui: "The connection was lost. Keep both devices near each other and try again.")
        case .cannotBeMade:
            Text(ui: "Your setup can't be sent: something in it is too large, or damaged.")
        case .unavailable:
            Text(ui: "Your setup couldn't be read on this device just now. Try again.")
        }
    }
}
