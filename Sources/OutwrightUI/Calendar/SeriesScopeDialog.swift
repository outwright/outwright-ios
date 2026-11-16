// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// What the owner is about to do to a repeating event, before choosing what it is for.
enum SeriesAction: Identifiable {
    case edit, delete
    var id: Self { self }
}

/// Asks whether an edit or a delete is for this occurrence ("This event") or the whole series.
struct SeriesScopeDialog: ViewModifier {
    @Binding var action: SeriesAction?
    /// The occurrence's own scope.
    let occurrence: EditScope?
    let choose: (SeriesAction, EditScope) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title, isPresented: isPresented, titleVisibility: .visible, presenting: action
        ) { action in
            if let occurrence {
                Button(role: action == .delete ? .destructive : nil) { choose(action, occurrence) } label: {
                    Text(ui: action == .delete ? "Delete this event" : "This event")
                }
                .accessibilityIdentifier("scope.occurrence")
            }
            Button(role: action == .delete ? .destructive : nil) { choose(action, .event) } label: {
                Text(ui: action == .delete ? "Delete all events in the series" : "All events in the series")
            }
            .accessibilityIdentifier("scope.series")
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: { action in
            Text(ui: action == .delete ? "This event repeats." : "This event repeats. What should the change be for?")
        }
    }

    private var title: Text {
        Text(ui: action == .delete ? "Delete a repeating event" : "Change a repeating event")
    }

    private var isPresented: Binding<Bool> {
        Binding { action != nil } set: { if !$0 { action = nil } }
    }
}

extension View {
    func seriesScopeDialog(
        _ action: Binding<SeriesAction?>, occurrence: EditScope?, choose: @escaping (SeriesAction, EditScope) -> Void
    ) -> some View {
        modifier(SeriesScopeDialog(action: action, occurrence: occurrence, choose: choose))
    }
}
