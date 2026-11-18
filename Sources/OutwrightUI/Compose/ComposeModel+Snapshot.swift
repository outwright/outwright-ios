// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel

/// What the message was when it started or was last kept, so closing asks only after a change;
/// and where writing begins in a body nobody has written in yet.
extension ComposeModel {
    struct Snapshot: Equatable {
        var from: AccountID
        var to: [Address]
        var cc: [Address]
        var bcc: [Address]
        var subject: String
        var body: AttributedString
        var files: [String]
        var ownerLock: Bool?
    }

    var current: Snapshot {
        Snapshot(
            from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
            files: attachments.map { "\($0.filename):\($0.data.count)" }, ownerLock: ownerLock)
    }

    public var hasChanges: Bool { current != snapshot }

    /// Where the cursor goes, in characters from the start, when the body is entered: the top,
    /// above the signature, while the body is as the message started. Nil once it is written in,
    /// and for a draft opened again, where the editor places it.
    public var cursorOnEntering: Int? {
        startingBody != nil && body == startingBody ? 0 : nil
    }
}
