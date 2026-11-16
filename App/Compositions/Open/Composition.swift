// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import OutwrightSync
import OutwrightUI

/// The open build's modules: each build's spec adds exactly one composition. The open build
/// carries the owner's own server and nothing more.
enum Composition {
    @MainActor
    static func modules(store: MailStore, folder: URL, hooks: [any LaunchHooks]) -> Modules {
        Modules()
    }

    /// The push methods this build adds after JMAP push: none. Apart from `modules`, since push is
    /// made when the app starts, before the store and the modules are.
    @MainActor
    static func pushMethods(credentials: CredentialProvider) -> [any PushMethod] {
        []
    }

    /// The token renewals of this build's OAuth providers, for push: none.
    @MainActor
    static func tokenRenewals() -> [ProviderID: any TokenRefreshing] {
        [:]
    }
}
