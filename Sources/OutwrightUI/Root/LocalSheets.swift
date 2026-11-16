// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

/// A sheet a screen shows over itself with nothing unsaved in it (a filter, a picker, an attachment):
/// the app knows it is open, and closes it when a tapped reminder needs the room. The sheet's own
/// `onDismiss` calls `openPending()`, which then shows the event.
struct ClosesForEvents: ViewModifier {
    @Environment(AppModel.self) private var app: AppModel?
    @State private var id = UUID()
    let isOpen: Bool
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isOpen, initial: true) { _, open in app?.localSheet(id, isOpen: open) }
            .onChange(of: app?.localSheetCloses) { _, _ in
                if isOpen { close() }
            }
            .onDisappear { app?.localSheet(id, isOpen: false) }
    }
}

extension View {
    func closesForEvents(isOpen: Bool, close: @escaping () -> Void) -> some View {
        modifier(ClosesForEvents(isOpen: isOpen, close: close))
    }
}
