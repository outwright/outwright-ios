// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The files iOS hands over when a setup file is opened from elsewhere.
extension SetupModel {
    /// Where iOS copies a file opened from elsewhere (the app's Documents/Inbox); none off iOS.
    public static var handedOverFolder: URL? {
        #if os(iOS)
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Inbox", isDirectory: true)
        #else
            nil
        #endif
    }

    /// A file iOS copied into the app's Documents/Inbox when it was opened from elsewhere.
    static func isHandedOver(_ url: URL) -> Bool {
        guard let inbox = handedOverFolder?.resolvingSymlinksInPath() else { return false }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path == inbox.path
    }

    /// Removes a handed-over file that will not be restored (another took its place).
    static func discardHandedOver(_ url: URL) {
        if isHandedOver(url) { try? FileManager.default.removeItem(at: url) }
    }
}
