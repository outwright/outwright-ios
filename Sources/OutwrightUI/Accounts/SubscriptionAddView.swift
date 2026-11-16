// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Adding a subscribed calendar: the address and a check of it, its name and colour.
struct SubscriptionAddView: View {
    @State var model: SubscriptionAddModel
    /// Told the new calendar once it is saved.
    var onAdded: (CalendarID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $model.address) { Text(verbatim: "https://… / webcal://…") }
                        .urlEntry()
                        .accessibilityIdentifier("subscription.address")
                    Button {
                        Task { await model.check() }
                    } label: {
                        Text(ui: "Check")
                    }
                    .disabled(model.address.isEmpty || model.state == .checking)
                    .accessibilityIdentifier("subscription.check")
                } header: {
                    Text(ui: "Address")
                } footer: {
                    status
                }
                Section {
                    LabeledContent {
                        TextField(text: $model.name) { Text(ui: "From the calendar") }
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("subscription.name")
                    } label: {
                        Text(ui: "Name")
                    }
                    CalendarColorPicker(color: $model.color)
                }
            }
            .navigationTitle(Text(ui: "Subscribed calendar"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if let added = await model.save() {
                                onAdded(added)
                                dismiss()
                            }
                        }
                    } label: {
                        Text(ui: "Save")
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("subscription.save")
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .editing: Text(ui: "The address is kept in the keychain: anyone who has it can read the calendar.")
        case .checking, .saving: ProgressView()
        case let .checked(preview): Text(ui: "\(preview.events) events found.")
        case let .failed(error): error.text.foregroundStyle(Theme.delete)
        }
    }
}

/// The palette's colours to pick from; nil is the palette's own choice.
struct CalendarColorPicker: View {
    @Binding var color: Int?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CalendarPalette.colors, id: \.self) { shade in
                Button {
                    color = shade
                } label: {
                    Circle()
                        .fill(Color(calendar: shade))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if color == shade {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subscription.color")
    }
}

extension View {
    /// A field for an address: no capitals, no corrections, the URL keyboard.
    func urlEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
