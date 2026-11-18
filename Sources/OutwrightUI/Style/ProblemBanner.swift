// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// A short line saying something failed, above the content it concerns; `accessory` (a button
/// that puts it right) at its end. With `onTap`, the line itself is a button too, beside the
/// accessory rather than around it.
struct ProblemBanner<Accessory: View>: View {
    let text: String
    var onTap: (@MainActor () -> Void)?
    var tapHint: Text?
    @ViewBuilder var accessory: Accessory

    init(
        text: String, onTap: (@MainActor () -> Void)? = nil, tapHint: Text? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.text = text
        self.onTap = onTap
        self.tapHint = tapHint
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let onTap {
                Button(action: onTap) {
                    HStack(spacing: 0) {
                        line
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(tapHint ?? Text(verbatim: ""))
            } else {
                line
                Spacer(minLength: 0)
            }
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.separator.opacity(0.6))
        .accessibilityElement(children: .contain)
    }
}

extension ProblemBanner where Accessory == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

extension ProblemBanner {
    private var line: some View {
        HStack(spacing: 8) {
            Image(systemName: Icons.warningFilled)
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
