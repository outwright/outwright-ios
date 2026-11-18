// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The header of an editing sheet (compose, the contact editor, the event editor): ✕ on the left, what
/// the thing goes to in the middle, ✓ on the right; at the accessibility sizes the middle goes under them.
struct EditorHeader<Middle: View>: View {
    let close: () -> Void
    let confirm: (() -> Void)?
    let confirmEnabled: Bool
    let confirmSymbol: String
    let confirmLabel: LocalizedStringKey
    let closeIdentifier: String?
    let confirmIdentifier: String?
    let middle: Middle

    init(
        close: @escaping () -> Void, confirm: (() -> Void)?, confirmEnabled: Bool,
        confirmSymbol: String = Icons.confirm, confirmLabel: LocalizedStringKey = "Save",
        closeIdentifier: String? = nil, confirmIdentifier: String? = nil,
        @ViewBuilder middle: () -> Middle
    ) {
        self.confirmSymbol = confirmSymbol
        self.confirmLabel = confirmLabel
        self.closeIdentifier = closeIdentifier
        self.confirmIdentifier = confirmIdentifier
        self.close = close
        self.confirm = confirm
        self.confirmEnabled = confirmEnabled
        self.middle = middle()
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At the accessibility sizes the middle has a row of its own under ✕ and ✓.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        closeButton
                        Spacer(minLength: 4)
                        confirmButton
                    }
                    middle
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    closeButton
                    middle
                    Spacer(minLength: 4)
                    confirmButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var closeButton: some View {
        GlassIconButton(Icons.close, label: "Close", action: close)
            .identified(closeIdentifier)
    }

    @ViewBuilder private var confirmButton: some View {
        if let confirm {
            GlassIconButton(
                confirmSymbol, label: confirmLabel, tint: confirmEnabled ? Theme.accent : Theme.secondaryText,
                action: confirm
            )
            .disabled(!confirmEnabled)
            .identified(confirmIdentifier)
        }
    }
}

private extension View {
    @ViewBuilder func identified(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}
