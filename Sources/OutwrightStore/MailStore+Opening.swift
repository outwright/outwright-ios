// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightMIME
public import OutwrightModel

extension MailStore {
    /// The way the build opens protected mail, asked for every stored message that is read.
    public func setOpening(_ opening: any MessageOpening) {
        self.opening.withLock { $0 = opening }
    }

    /// `raw` as the owner reads it: opened when the build can, else as it is. Nil when it won't read.
    public func open(_ raw: Data, limits: MIMELimits = .default) -> OpenedMessage? {
        let opener = opening.withLock { $0 }
        return MessageReader.read(raw, limits: limits, opening: opener)
    }

    /// The stored message, opened; nil when it has no body or the body won't read.
    public func opened(_ id: MessageID, limits: MIMELimits = .default) throws(StoreError) -> OpenedMessage? {
        guard let raw = try body(id) else { return nil }
        return open(raw, limits: limits)
    }
}
