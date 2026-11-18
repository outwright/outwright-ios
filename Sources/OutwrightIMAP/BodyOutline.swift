// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A `text/calendar` part of a message, as its BODYSTRUCTURE (RFC 9051 §7.5.2) describes it: its
/// `method` parameter, nil when it has none.
public struct CalendarPartOutline: Sendable, Equatable {
    public var method: String?

    public init(method: String?) {
        self.method = method
    }
}

/// Reads a BODYSTRUCTURE for the message's own calendar parts. A part inside an attached message
/// (`message/rfc822`) is that message's, not this one's, and is left out. The tree is the server's,
/// so the walk is bounded in depth and in parts.
enum BodyOutline {
    /// The most calendar parts kept, and ten times as many parts looked at.
    static let maxParts = 16
    static let maxDepth = 16

    static func calendarParts(_ structure: IMAPValue?) -> [CalendarPartOutline] {
        guard let structure else { return [] }
        var walk = Walk()
        walk.visit(structure, depth: 0)
        return walk.found
    }

    private struct Walk {
        var found: [CalendarPartOutline] = []
        var looked = 0

        mutating func visit(_ body: IMAPValue, depth: Int) {
            guard depth < BodyOutline.maxDepth, looked < BodyOutline.maxParts * 10,
                found.count < BodyOutline.maxParts, case let .list(items) = body, let first = items.first
            else { return }
            looked += 1
            // A multipart's children come first, each a list; its subtype follows them.
            if case .list = first {
                for child in items {
                    guard case .list = child else { break }
                    visit(child, depth: depth + 1)
                }
                return
            }
            guard items.count >= 3, items[0].text?.lowercased() == "text",
                items[1].text?.lowercased() == "calendar"
            else { return }
            found.append(CalendarPartOutline(method: Self.parameter("method", in: items[2])))
        }

        /// A parameter of a `("name" "value" ...)` list, by name in any case.
        static func parameter(_ name: String, in value: IMAPValue) -> String? {
            guard case let .list(pairs) = value else { return nil }
            var index = 0
            while index + 1 < pairs.count {
                if pairs[index].text?.lowercased() == name { return pairs[index + 1].text }
                index += 2
            }
            return nil
        }
    }
}
