// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// A password or token held in memory. It prints, debug-prints and dumps as `<secret>`;
/// only `reveal()` gives the value, at the one place it is written to a server.
public struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func reveal() -> String {
        value
    }

    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
