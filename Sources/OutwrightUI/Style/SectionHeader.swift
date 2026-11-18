// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI

/// The heading of a group in a list (a day, a letter, Favorites): one style everywhere. Form headers
/// stay as the system draws them.
public struct SectionHeader: View {
    private let title: Text
    /// The colour of the text; the secondary text colour when nil (today, in the calendar, is tinted).
    private let tint: Color?

    public init(_ title: LocalizedStringKey, tint: Color? = nil) {
        self.title = Text(title, bundle: .module)
        self.tint = tint
    }

    public init(verbatim: String, tint: Color? = nil) {
        self.title = Text(verbatim: verbatim)
        self.tint = tint
    }

    public var body: some View {
        title
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint ?? Theme.secondaryText)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}
