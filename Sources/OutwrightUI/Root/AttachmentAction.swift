// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightMIME
public import OutwrightModel
public import SwiftUI

/// What a module adds to the menu of an attachment: its title and the view shown in a sheet.
public struct AttachmentActionItem {
    public let title: Text
    public let systemImage: String
    public let perform: @MainActor () -> AnyView

    public init(title: Text, systemImage: String, perform: @escaping @MainActor () -> AnyView) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// A module's action on attachments, joined to the shared code at app start. Asked for every
/// attachment shown; it answers nil for one it has nothing to do with.
@MainActor public protocol AttachmentAction: AnyObject {
    func action(for attachment: Attachment, account: Account?) -> AttachmentActionItem?
}
