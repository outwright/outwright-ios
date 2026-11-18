// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// What Send stopped to ask about protection: recipients without a key, or a message that can't be
/// protected from the account yet; the recipients a key is being added for; whether the account is
/// being set up to encrypt; and the person whose key is being looked at.
struct ProtectionQuestions {
    var choosing: Binding<[Address]>
    var unprotectable: Binding<Bool>
    var addingKeys: Binding<[Address]>
    var settingUp: Binding<Bool>
    var personKey: Binding<String?>
    /// Where the account is set up to encrypt (asked once per account); nil: nothing to set up.
    var setup: AnyView?
}

extension View {
    /// Asks the protection again when a recipient is added or removed, or the account changes (not per
    /// keystroke), and, when sending stopped on recipients who can't receive a protected message or on a
    /// message that can't be protected from the account yet, asks what to do.
    func askingAboutProtection(
        model: ComposeModel, app: AppModel, questions: ProtectionQuestions, send: @escaping (ProtectionChoice) -> Void
    ) -> some View {
        let (choosing, unprotectable, addingKeys) = (questions.choosing, questions.unprotectable, questions.addingKeys)
        let setup = questions.setup
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
            if setup != nil {
                Button { questions.settingUp.wrappedValue = true } label: {
                    Text(ui: "Set up encryption for this account")
                }
            }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        }
        .protectionSheets(model: model, app: app, questions: questions, setup: setup)
    }

    /// The sheets compose opens about protection: setting the account up, a recipient's key, and
    /// adding keys. Each asks the protection again when it closes.
    private func protectionSheets(
        model: ComposeModel, app: AppModel, questions: ProtectionQuestions, setup: AnyView?
    ) -> some View {
        let addingKeys = questions.addingKeys
        return sheet(isPresented: questions.settingUp) {
            setup
                .onDisappear { Task { await model.refreshProtection() } }
        }
        .sheet(
            isPresented: Binding(
                get: { questions.personKey.wrappedValue != nil },
                set: { if !$0 { questions.personKey.wrappedValue = nil } })
        ) {
            if let address = questions.personKey.wrappedValue, let screens = model.protectionUI {
                PersonKeySheet(section: screens.personSection(for: address))
                    .onDisappear { Task { await model.refreshProtection() } }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !addingKeys.wrappedValue.isEmpty }, set: { if !$0 { addingKeys.wrappedValue = [] } })
        ) {
            KeyList(addresses: addingKeys.wrappedValue, screens: model.protectionUI, account: model.account)
                .onDisappear { Task { await model.refreshProtection() } }
        }
    }
}

/// The recipients without a key, each opening where a key for it is added.
private struct KeyList: View {
    let addresses: [Address]
    let screens: (any ProtectionUI)?
    /// The account the message is from.
    let account: Account?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(addresses, id: \.email) { address in
                NavigationLink {
                    screens?.keyImporter(for: address.email, account: account)
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

/// A recipient's key, as their card shows it, opened from their chip in compose.
private struct PersonKeySheet: View {
    let section: AnyView
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                section.padding(16)
            }
            .background(Theme.drawerBackground)
            .navigationTitle(Text(ui: "Key"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }
}
