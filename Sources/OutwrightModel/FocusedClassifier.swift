// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME

/// Sorts incoming mail into Focused and Other.
public enum FocusedClassifier {
    /// An override wins. Else Focused when the sender is somebody the owner writes to, or the message
    /// replies in a thread the owner took part in, or the message is not bulk. Else Other.
    /// `correspondents` and `overrides` are keyed by lower-case address.
    public static func classify(
        from: Address, isBulk: Bool, isReplyToOwn: Bool, correspondents: Set<String>,
        overrides: [String: InboxClass]
    ) -> InboxClass {
        let key = from.email.lowercased()
        if let forced = overrides[key] { return forced }
        if correspondents.contains(key) || isReplyToOwn || !isBulk { return .focused }
        return .other
    }
}
