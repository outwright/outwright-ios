// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The mark of an account that needs attention: a small warning dot, ringed in the colour behind it
/// (`ring`: the header's, the drawer's, a grouped row's) so it stands off the avatar it sits on.
struct AttentionDot: View {
    let ring: Color
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.warning)
            .frame(width: size, height: size)
            .padding(size / 4)
            .background(Circle().fill(ring))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The attention dot at the top right when `shown`, and VoiceOver told so.
    func attentionDot(_ shown: Bool, ring: Color) -> some View {
        overlay(alignment: .topTrailing) {
            if shown {
                AttentionDot(ring: ring).offset(x: 2, y: -2)
            }
        }
        .modifier(AttentionValue(shown: shown))
    }
}

/// "Needs attention" as the VoiceOver value, only when it does.
private struct AttentionValue: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        if shown {
            content.accessibilityValue(Text(ui: "Needs attention"))
        } else {
            content
        }
    }
}
