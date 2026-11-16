// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightMIME

extension ComposeModel {
    /// Why a file was not attached.
    public enum AttachProblem: Sendable, Equatable {
        case tooLarge, unreadable
    }

    /// Attaches the file at `url`, read only as far as the room left allows; nil when it was added.
    func attachFile(_ url: URL, filename: String, mimeType: String) -> AttachProblem? {
        switch AttachmentReader.read(url, limit: attachmentRoom) {
        case .read(let data):
            let added = attach(
                Attachment(filename: filename, mimeType: mimeType, contentID: nil, isInline: false, data: data))
            return added ? nil : .tooLarge
        case .tooLarge:
            return .tooLarge
        case .unreadable:
            return .unreadable
        }
    }

    /// Room left for attachments, in bytes.
    var attachmentRoom: Int {
        max(attachmentLimit - attachmentBytes, 0)
    }

    /// Adds a file, unless the message would grow past 25 MB of attachments.
    @discardableResult
    public func attach(_ attachment: Attachment) -> Bool {
        guard attachmentBytes + attachment.data.count <= attachmentLimit else { return false }
        attachments.append(attachment)
        return true
    }

    var attachmentBytes: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }
}
