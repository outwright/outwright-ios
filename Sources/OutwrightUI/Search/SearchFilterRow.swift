// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightStore
import SwiftUI

/// Over a list of mail in search: Filter (unread, flagged, any of them at once), Has attachments,
/// and Older than 6 months.
struct SearchFilterRow: View {
    @Bindable var model: SearchModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Toggle(isOn: $model.filter.unread) { ModuleLabel("Unread", systemImage: Icons.unread) }
                    Toggle(isOn: $model.filter.flagged) { ModuleLabel("Flagged", systemImage: Icons.flagOutline) }
                } label: {
                    HStack(spacing: 6) {
                        if model.filter.count > 0 {
                            Text(verbatim: "\(model.filter.count)")
                                .font(.footnote.bold())
                                .foregroundStyle(Theme.onAccent)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Theme.accent, in: Circle())
                        } else {
                            Image(systemName: Icons.filter)
                        }
                        Text(ui: "Filter")
                    }
                    .modifier(FilterCapsule(isOn: model.filter.count > 0))
                }
                toggle("Has attachments", isOn: $model.filter.attachments)
                toggle("Older than 6 months", isOn: $model.olderThanSixMonths)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("search.filters")
    }

    private func toggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(ui: title).modifier(FilterCapsule(isOn: isOn.wrappedValue))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

private struct FilterCapsule: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isOn ? Theme.accentSoft : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(Theme.separator))
    }
}
