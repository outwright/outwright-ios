// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import SwiftUI

/// What Send stopped to ask about protection: recipients without a key, or a message that can't be
/// protected from the account yet; and the recipients a key is being added for.
struct ProtectionQuestions {
    var choosing: Binding<[Address]>
    var unprotectable: Binding<Bool>
    var addingKeys: Binding<[Address]>
}

extension View {
    /// Asks the protection again when a recipient is added or removed, or the account changes (not per
    /// keystroke), and, when sending stopped on recipients who can't receive a protected message or on a
    /// message that can't be protected from the account yet, asks what to do.
    func askingAboutProtection(
        model: ComposeModel, app: AppModel, questions: ProtectionQuestions, send: @escaping (ProtectionChoice) -> Void
    ) -> some View {
        let (choosing, unprotectable, addingKeys) = (questions.choosing, questions.unprotectable, questions.addingKeys)
        return task(id: (model.to + model.cc + model.bcc).map { $0.email.lowercased() } + [model.from.raw.uuidString]) {
            await model.refreshProtection()
        }
        .confirmationDialog(
            Text(ui: "Some recipients can't receive encrypted mail"),
            isPresented: Binding(
                get: { !choosing.wrappedValue.isEmpty }, set: { if !$0 { choosing.wrappedValue = [] } }),
            titleVisibility: .visible
        ) {
            Button { send(.sendPlain) } label: { Text(ui: "Send without encryption") }
            Button { send(.removeKeyless) } label: { Text(ui: "Remove recipients without a key") }
            Button { addingKeys.wrappedValue = choosing.wrappedValue } label: { Text(ui: "Add a key") }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: {
            Text(verbatim: choosing.wrappedValue.map(\.email).joined(separator: ", "))
        }
        .confirmationDialog(
            Text(ui: "This message can't be encrypted from this account yet"), isPresented: unprotectable,
            titleVisibility: .visible
        ) {
            Button { send(.sendPlain) } label: { Text(ui: "Send without encryption") }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        }
        .sheet(
            isPresented: Binding(
                get: { !addingKeys.wrappedValue.isEmpty }, set: { if !$0 { addingKeys.wrappedValue = [] } })
        ) {
            KeyList(addresses: addingKeys.wrappedValue, app: app)
                .onDisappear { Task { await model.refreshProtection() } }
        }
    }
}

/// The recipients without a key, each opening where a key for it is added.
private struct KeyList: View {
    let addresses: [Address]
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(addresses, id: \.email) { address in
                NavigationLink {
                    app.modules.protectionUI?.keyImporter(for: address.email)
                } label: {
                    Text(verbatim: address.email)
                }
            }
            .navigationTitle(Text(ui: "Add a key"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }
}
