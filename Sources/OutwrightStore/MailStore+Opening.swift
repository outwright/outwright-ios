// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightMIME
public import OutwrightModel

extension MailStore {
    /// The ways the build opens protected mail, asked in order for every stored message that is read.
    public func setOpenings(_ openings: [any MessageOpening]) {
        self.openings.withLock { $0 = openings }
    }

    /// `raw` as the owner reads it: opened when the build can, else as it is. Nil when it won't read.
    /// `account`: the account it is on, when known (an opening may trust per account).
    public func open(_ raw: Data, limits: MIMELimits = .default, account: AccountID? = nil) -> OpenedMessage? {
        let openers = openings.withLock { $0 }
        return MessageReader.read(raw, limits: limits, openings: openers, account: account?.raw.uuidString)
    }

    /// The stored message, opened with its account; nil when it has no body or the body won't read.
    public func opened(_ id: MessageID, limits: MIMELimits = .default) throws(StoreError) -> OpenedMessage? {
        guard let raw = try body(id) else { return nil }
        return open(raw, limits: limits, account: try message(id)?.accountID)
    }
}
