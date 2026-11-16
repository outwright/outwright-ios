// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// What a list's side pane shows: which item stays selected when the list changes, and how an open
/// item carries over when the screen turns between one column and two.
enum PaneSelection {
    /// The selection after the list changed from `old` to `new`: the same item while it is still in
    /// the list, else the first one after it that remains, else the nearest one before it, else none.
    /// An item that was never in the list (opened from a notification or a search) stays.
    static func following<ID: Hashable>(_ selected: ID?, old: [ID], new: [ID]) -> ID? {
        guard let selected else { return nil }
        let remaining = Set(new)
        if remaining.contains(selected) { return selected }
        guard let index = old.firstIndex(of: selected) else { return selected }
        if let next = old[old.index(after: index)...].first(where: remaining.contains) { return next }
        return old[..<index].last(where: remaining.contains)
    }

    /// The one-column path and the two-column selection after a turn. Going wide, the open item becomes
    /// the selection (none when the list was showing); going narrow, the selection is opened and the
    /// path holds it from then on.
    static func carry<ID: Hashable>(path: [ID], selected: ID?, wide: Bool) -> (path: [ID], selected: ID?) {
        if wide { return ([], path.last) }
        if let selected { return ([selected], nil) }
        return (path, nil)
    }
}
