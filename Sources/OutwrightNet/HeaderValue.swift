// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Values written into a header or a protocol line.
public enum HeaderValue {
    /// The value with CR, LF and NUL taken out (values can come from the server).
    public static func clean(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
    }
}
