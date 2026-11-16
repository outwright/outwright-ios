// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightSync

/// The open build's part of the notification extension: each build's spec adds exactly one. The
/// open build has no OAuth provider and no push method that renews from the extension.
enum ExtensionComposition {
    /// The token renewals of this build's OAuth providers, for the new-mail probe: none.
    static func tokenRenewals() -> [ProviderID: any TokenRefreshing] {
        [:]
    }

    /// The push methods the extension renews when a push arrives: none.
    static func pushMethods(credentials: CredentialProvider) -> [any PushMethod] {
        []
    }
}
