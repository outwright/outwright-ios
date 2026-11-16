// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightSync

/// Where the app and its notification extension keep push state: the registry and the
/// watermarks in the shared app group's container. Nil where there is no container (an unsigned
/// or simulator build): push is then unavailable.
enum PushPlaces {
    /// The build's app group (Info.plist `OutwrightAppGroup`); none in the open build.
    static var container: URL? {
        guard let appGroup = BuildSettings.main.appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func registry(in container: URL) -> URL {
        container.appendingPathComponent("push-registry.json")
    }

    static func watermarks(in container: URL) -> URL {
        container.appendingPathComponent("push-watermarks.json")
    }
}
