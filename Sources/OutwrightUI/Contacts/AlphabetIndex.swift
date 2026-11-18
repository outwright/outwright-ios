// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The letters that have a section, down the right edge, thinned to fit the height
/// (`ContactsModel.indexLetters`); a touch or a drag over them jumps to the letter's section. To
/// VoiceOver it is one adjustable element: swipe up or down to step through the letters.
struct AlphabetIndex: View {
    let model: ContactsModel
    let jump: (String) -> Void
    @State private var last: String?
    /// The letter VoiceOver stands on.
    @State private var current: String?

    var body: some View {
        GeometryReader { geometry in
            let entries = model.indexLetters(height: geometry.size.height)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Text(verbatim: entry.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        // Each letter has its 14 points, so it doesn't grow past them with the text size.
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .frame(maxWidth: .infinity)
                        .frame(height: ContactsModel.pointsPerEntry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in touch(at: value.location.y, in: geometry.size.height, entries) }
                    .onEnded { _ in last = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(ui: "Index"))
            .accessibilityValue(Text(verbatim: current ?? entries.first?.letter ?? ""))
            .accessibilityAdjustableAction { direction in step(direction, letters: model.sections.map(\.letter)) }
            .accessibilityHidden(entries.isEmpty)
            .opacity(entries.isEmpty ? 0 : 1)
        }
        .frame(width: 22)
    }

    /// The entry under the finger, the entries standing centred in `height`.
    private func touch(at offset: CGFloat, in height: CGFloat, _ entries: [IndexEntry]) {
        guard !entries.isEmpty, height > 0 else { return }
        let used = CGFloat(entries.count) * ContactsModel.pointsPerEntry
        let top = max(0, (height - used) / 2)
        let fraction = min(max((offset - top) / max(used, 1), 0), 0.999_999)
        let index = Int(fraction * Double(entries.count))
        guard entries.indices.contains(index) else { return }
        let target = entries[index].letter
        if target != last {
            last = target
            jump(target)
        }
    }

    private func step(_ direction: AccessibilityAdjustmentDirection, letters: [String]) {
        guard !letters.isEmpty else { return }
        let place = current.flatMap { letters.firstIndex(of: $0) } ?? 0
        let next: Int
        switch direction {
        case .increment: next = min(place + 1, letters.count - 1)
        case .decrement: next = max(place - 1, 0)
        @unknown default: return
        }
        guard letters.indices.contains(next) else { return }
        current = letters[next]
        jump(letters[next])
    }
}
