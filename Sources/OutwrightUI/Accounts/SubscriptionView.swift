// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// One subscribed calendar: rename, colour, fetch now, remove.
struct SubscriptionView: View {
    let app: AppModel
    @State var subscription: CalendarSubscription
    let changed: () -> Void
    @State private var name: String
    @State private var color: Int?
    @State private var isRefreshing = false
    @State private var isConfirmingRemoval = false
    @State private var failure: SubscriptionAddError?
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, subscription: CalendarSubscription, changed: @escaping () -> Void) {
        self.app = app
        _subscription = State(initialValue: subscription)
        self.changed = changed
        _name = State(initialValue: subscription.calendar.name)
        _color = State(initialValue: subscription.calendar.color)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField(text: $name) { Text(ui: "Name") }
                        .multilineTextAlignment(.trailing)
                        .onSubmit { save() }
                        .accessibilityIdentifier("subscription.name")
                } label: {
                    Text(ui: "Name")
                }
                CalendarColorPicker(color: $color)
                    .onChange(of: color) { save() }
            }
            Section {
                LabeledContent {
                    Text(verbatim: subscription.host)
                } label: {
                    Text(ui: "Server")
                }
                SubscriptionRow(subscription: subscription)
                Button {
                    isRefreshing = true
                    Task {
                        await app.refreshSubscription(subscription.id)
                        reload()
                        isRefreshing = false
                    }
                } label: {
                    Text(ui: "Refresh now")
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("subscription.refresh")
            }
            Section {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text(ui: "Remove subscribed calendar")
                }
                .accessibilityIdentifier("subscription.remove")
            } footer: {
                if let failure { failure.text.foregroundStyle(Theme.delete) }
            }
        }
        .navigationTitle(Text(verbatim: subscription.calendar.name))
        .onDisappear { save() }
        .confirmationDialog(
            Text(ui: "Remove this calendar from Outwright? The published calendar stays as it is."),
            isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                remove()
            } label: {
                Text(ui: "Remove subscribed calendar")
            }
        }
    }

    private func remove() {
        do throws(SubscriptionAddError) {
            try app.removeSubscription(subscription.id)
            changed()
            dismiss()
        } catch {
            failure = error
        }
    }

    private func save() {
        let title = name.trimmingCharacters(in: .whitespaces)
        let shade = color ?? subscription.calendar.color
        let calendar = subscription.calendar
        guard !title.isEmpty, title != calendar.name || shade != calendar.color else { return }
        do {
            try app.updateSubscription(subscription.id, name: title, color: shade)
            reload()
            changed()
        } catch {
            failure = error
        }
    }

    private func reload() {
        let held = app.subscriptions()
        if let fresh = held.first(where: { $0.id == subscription.id }) {
            subscription = fresh
        }
    }
}
