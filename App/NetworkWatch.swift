// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Network

/// Tells the app when the phone is on another network (Wi-Fi to mobile, another Wi-Fi, back
/// after none): the IDLE connections may then be dead without a word, and are opened again.
@MainActor
enum NetworkWatch {
    private static var monitor: NWPathMonitor?
    private static var last: String?

    /// Starts watching, once; `changed` runs on the main actor for each new usable network.
    static func start(_ changed: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let usable = path.status == .satisfied
            // The gateways tell one Wi-Fi from the next, which keeps the interface's name.
            let parts = path.availableInterfaces.map(\.name) + path.gateways.map { "\($0)" }
            let signature = usable ? parts.joined(separator: ",") : ""
            Task { @MainActor in
                // The first answer is the network the app started on, not a change.
                defer { last = signature }
                guard let previous = last, previous != signature, usable else { return }
                changed()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.10boring.outwright.network"))
        self.monitor = monitor
    }
}
