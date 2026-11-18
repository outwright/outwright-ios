// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI

/// A round glass button with one symbol: the close, confirm and send buttons of a sheet's header.
public struct GlassIconButton: View {
    private let systemImage: String
    private let label: LocalizedStringKey
    private let tint: Color?
    private let action: () -> Void
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 48
    /// Grows with the text, but never so far that a header's buttons crowd out what stands between them.
    private var size: CGFloat { min(diameter, 68) }

    /// - Parameter tint: the colour of the symbol, for instance the accent while the button can act and the
    ///   secondary text colour while it can't; the primary text colour when nil.
    public init(_ systemImage: String, label: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text(label, bundle: .module))
    }
}
