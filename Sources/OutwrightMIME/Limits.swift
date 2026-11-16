// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Bounds applied to every message read, because every message is hostile.
public struct MIMELimits: Sendable {
    public var messageBytes: Int
    public var headerBytes: Int
    public var depth: Int
    public var parts: Int
    /// The most bytes of the plain text read (after its transfer encoding is undone); nil for all.
    public var textBytes: Int?
    /// The largest `text/calendar` part read as the message's calendar; a larger one is only an attachment.
    public var calendarPartBytes: Int

    public init(
        messageBytes: Int = 64 << 20, headerBytes: Int = 1 << 20, depth: Int = 32, parts: Int = 1_000,
        textBytes: Int? = nil, calendarPartBytes: Int = 512 << 10
    ) {
        self.messageBytes = messageBytes
        self.headerBytes = headerBytes
        self.depth = depth
        self.parts = parts
        self.textBytes = textBytes
        self.calendarPartBytes = calendarPartBytes
    }

    public static let `default` = MIMELimits()
}
