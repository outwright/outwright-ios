// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import SwiftUI

/// One difference at a time, after the button: what differs, for which account, and whether this
/// device takes the other side's. No secret is ever shown, only that one differs.
enum SetupQuestion {
    /// The question, naming the account and where the other side is.
    static func text(_ difference: SetupDifference, source: SetupReportForm.Source) -> Text {
        let address = difference.label
        switch (difference.kind, source) {
        case (.accountSecret, .device):
            return Text(ui: "The password for \(address) is different on your other device. Use it here?")
        case (.accountSecret, .file):
            return Text(ui: "The password for \(address) is different in the file. Use it here?")
        case (.ownKey, .device):
            return Text(
                ui: """
                    Your other device uses a different key for \(address). Use it here? This device's key \
                    stays, so older mail still opens.
                    """)
        case (.ownKey, .file):
            return Text(
                ui: """
                    The file has a different key for \(address). Use it here? This device's key stays, so \
                    older mail still opens.
                    """)
        case (.signature, .device):
            return Text(ui: "The signature for \(address) is different on your other device. Use it here?")
        case (.signature, .file):
            return Text(ui: "The signature for \(address) is different in the file. Use it here?")
        case (.servers, .device):
            return Text(ui: "The server details for \(address) are different on your other device. Use them here?")
        case (.servers, .file):
            return Text(ui: "The server details for \(address) are different in the file. Use them here?")
        }
    }

    /// The button that takes the other side's.
    static func use(_ difference: SetupDifference) -> Text {
        difference.kind == .servers ? Text(ui: "Use them") : Text(ui: "Use it")
    }
}

extension View {
    /// Shows the model's question, while there is one, as an alert.
    func setupQuestion(_ model: SetupModel, source: SetupReportForm.Source) -> some View {
        alert(
            Text(ui: "Different on this device"),
            isPresented: Binding(get: { model.question != nil }, set: { _ in }),
            presenting: model.question
        ) { difference in
            Button { model.answer(useOther: true) } label: { SetupQuestion.use(difference) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.question.use")
            Button(role: .cancel) { model.answer(useOther: false) } label: { Text(ui: "Keep this one") }
                .accessibilityIdentifier("setup.question.keep")
        } message: { difference in
            SetupQuestion.text(difference, source: source)
        }
    }
}
