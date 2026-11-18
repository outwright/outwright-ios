// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// An OAuth account's sign-in: offered again, by its provider, once it is gone.
extension AccountSettingsView {
    @ViewBuilder var providerSignInSection: some View {
        if app.needsSignInAgain(account.id), let provider = app.provider(of: account) {
            Section {
                SignInAgainButton(app: app, account: account)
            } header: {
                Text(provider.signInHeader)
            } footer: {
                if let note = provider.addNote {
                    Text(note)
                }
            }
        }
    }

    /// Shown instead of the account's settings when this build lacks its provider.
    @ViewBuilder var unavailableSection: some View {
        Section {
            Text(ui: "Not available in this version of Outwright. The account is kept as it is.")
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
