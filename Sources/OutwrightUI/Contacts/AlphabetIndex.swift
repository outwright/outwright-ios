// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The letters down the right edge; a touch or a drag over them jumps to the letter's section.
struct AlphabetIndex: View {
    let letters: [String]
    /// The letters that have a section.
    let available: Set<String>
    let jump: (String) -> Void
    @State private var last: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(verbatim: letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(available.contains(letter) ? Theme.accent : Theme.secondaryText.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.height > 0, !letters.isEmpty else { return }
                        let fraction = min(max(value.location.y / geometry.size.height, 0), 0.999_999)
                        let index = Int(fraction * Double(letters.count))
                        guard letters.indices.contains(index) else { return }
                        let target = Self.target(from: index, in: letters, available: available)
                        if let target, target != last {
                            last = target
                            jump(target)
                        }
                    }
                    .onEnded { _ in last = nil }
            )
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }

    /// The letter at the index if it has a section, else the next one that has, else the last that has.
    static func target(from index: Int, in letters: [String], available: Set<String>) -> String? {
        guard letters.indices.contains(index) else { return nil }
        if let next = letters[index...].first(where: { available.contains($0) }) { return next }
        return letters.last { available.contains($0) }
    }
}
