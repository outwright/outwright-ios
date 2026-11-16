// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// What of a message's HTML is never text for a reader.
extension HTMLText {
    /// Elements whose content is not text: style sheets, scripts and the head (with its title).
    static let hidden = ["head", "style", "script"]

    /// The HTML without its `head`, `style` and `script` elements and their content (case does
    /// not matter; an element left open runs to the end). Bounded: at most 1,000 elements go.
    public static func removingHiddenElements(_ html: String) -> String {
        var out = ""
        var rest = html[...]
        for _ in 0..<1_000 {
            guard let (open, name) = firstHiddenOpening(in: rest) else { break }
            out += rest[..<open]
            let after = rest[open...]
            if let close = after.range(of: "</" + name, options: .caseInsensitive),
               let end = after[close.upperBound...].firstIndex(of: ">") {
                rest = after[after.index(after: end)...]
            } else {
                rest = ""
            }
        }
        return out + rest
    }

    /// The first `<head`, `<style` or `<script` that opens an element of that name.
    private static func firstHiddenOpening(in text: Substring) -> (String.Index, String)? {
        var best: (String.Index, String)?
        for name in hidden {
            var search = text
            while let found = search.range(of: "<" + name, options: .caseInsensitive) {
                let next = search[found.upperBound...].first
                if next == nil || next == ">" || next == "/" || next?.isWhitespace == true {
                    if best.map({ found.lowerBound < $0.0 }) ?? true {
                        best = (found.lowerBound, name)
                    }
                    break
                }
                search = search[found.upperBound...]
            }
        }
        return best
    }
}
