// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI

/// Private support over HTTPS, even when the owner's mail cannot be sent.
struct SupportFormView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var message = ""
    @State private var includeDiagnostics: Bool
    @State private var report: Data?
    @State private var preparing = true
    @State private var sending = false
    @State private var sent = false
    @State private var failure: SupportSendError?

    init(app: AppModel, includeDiagnostics: Bool) {
        self.app = app
        _email = State(initialValue: app.accounts.first?.email ?? "")
        _includeDiagnostics = State(initialValue: includeDiagnostics)
    }

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section { Text(ui: "Your support request has been sent.") }
                } else {
                    Section {
                        TextField(text: $email) { Text(ui: "Reply email address") }
                            .emailEntry()
                            .accessibilityIdentifier("support.email")
                        TextField(text: $message, axis: .vertical) { Text(ui: "How can we help?") }
                            .lineLimit(4...10)
                            .accessibilityIdentifier("support.message")
                    } footer: {
                        Text(ui: "Sent directly to support. Your mail account does not need to work.")
                    }
                    Section {
                        Toggle(isOn: $includeDiagnostics) { Text(ui: "Include diagnostics") }
                            .accessibilityIdentifier("support.includeDiagnostics")
                        if includeDiagnostics {
                            if preparing {
                                ProgressView()
                            } else if let report {
                                NavigationLink {
                                    ScrollView {
                                        Text(verbatim: String(bytes: report, encoding: .utf8) ?? "")
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding()
                                    }
                                    .navigationTitle(Text(ui: "Diagnostics"))
                                } label: { Text(ui: "Read the report") }
                            }
                        }
                    } footer: {
                        Text(ui: "The report holds no mail, addresses or server names. You can read it before sending.")
                    }
                    if let failure {
                        Section { Text(errorText(failure)).foregroundStyle(Theme.delete) }
                    }
                }
            }
            .disabled(sending)
            .navigationTitle(Text(ui: "Help and support"))
            .inlineNavigationTitle()
            .interactiveDismissDisabled(sending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                        .disabled(sending)
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            sending = true
                            failure = nil
                            Task {
                                do {
                                    try await SupportClient().send(SupportSubmission(
                                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                        message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? "Diagnostics report" : message,
                                        diagnostics: includeDiagnostics ? report : nil))
                                    sent = true
                                } catch let error as SupportSendError {
                                    failure = error
                                } catch {
                                    failure = .failed
                                }
                                sending = false
                            }
                        } label: {
                            if sending { ProgressView() } else { Text(ui: "Send") }
                        }
                        .disabled(sending || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (includeDiagnostics && preparing)
                            || (!includeDiagnostics && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("support.send")
                    }
                }
            }
            .task {
                report = await app.diagnosticsReport()
                preparing = false
            }
        }
    }

    private func errorText(_ error: SupportSendError) -> String {
        switch error {
        case .invalidRequest: L10n.string("Check the reply address and keep your message under 8,000 characters.")
        case .reportTooLarge: L10n.string("The report is too large. Turn off diagnostics to send your message.")
        case .rateLimited: L10n.string("Too many requests. Please try again in an hour.")
        case .failed: L10n.string("Delivery could not be confirmed. Your message is still here so you can try again.")
        }
    }
}
