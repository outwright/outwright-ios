// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// On a phone, a message or a contact's card pushed over its list has the screen, without the tabs.
/// The tabs come back with the list: as a swipe back begins, or when nothing is pushed.
enum PushedList {
    /// Something is pushed and its list is not coming back into view (a swipe back brings it).
    static func covers<Item>(path: [Item], listInView: Bool) -> Bool {
        !path.isEmpty && !listInView
    }

    /// Whether the list is in view as it appears. With nothing pushed it is. With something pushed it
    /// is coming back as a swipe back begins, unless it appears because its tab came back
    /// (`tabReturning`): then what is pushed keeps the screen, whether this comes before or after the
    /// tab's change is seen.
    static func inViewOnAppear<Item>(path: [Item], tabReturning: Bool) -> Bool {
        path.isEmpty || !tabReturning
    }
}
