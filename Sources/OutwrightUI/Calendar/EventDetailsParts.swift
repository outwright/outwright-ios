// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Join for a meeting: opens its link outside the app on the owner's tap. Filled under an event's
/// title, smaller on an agenda row.
struct JoinButton: View {
    let url: URL
    var prominent = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            Label { Text(ui: "Join") } icon: { Image(systemName: Icons.join) }
                .font(prominent ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .frame(minHeight: prominent ? 36 : 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .accessibilityHint(Text(verbatim: url.host() ?? url.absoluteString))
        .accessibilityIdentifier("event.join")
    }
}

extension EventDetailsView {
    // swiftlint:disable:next line_length
    static let conflictMessage: LocalizedStringKey = "The event was changed on the server meanwhile. Apply your change again on top of the new version, or discard it."
    // swiftlint:disable:next line_length
    static let conflictsMessage: LocalizedStringKey = "The event was changed on the server meanwhile. Apply your changes again, in order, on top of the new version, or discard them."

    func row(_ icon: String, @ViewBuilder _ body: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6, content: body)
            Spacer(minLength: 0)
        }
    }

    static func color(_ response: Attendee.Response) -> Color {
        switch response {
        case .accepted: Theme.success
        case .declined: Theme.delete
        case .tentative: Theme.warning
        case .delegated, .needsAction: Theme.secondaryText
        }
    }

    static func response(_ response: Attendee.Response) -> LocalizedStringKey {
        switch response {
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .tentative: "Tentative"
        case .delegated: "Delegated"
        case .needsAction: "No answer yet"
        }
    }
}
