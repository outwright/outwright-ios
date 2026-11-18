// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// How Add account ended.
struct AddAccountOutcome {
    let account: Account
    /// The address was already on the phone and its sign-in was renewed.
    let signedInAgain: Bool
}

/// What follows Add account: the account is on the phone, with Add another account and Done. An
/// account only signed in again is told about for a moment, and the screen closes by itself.
struct AccountAddedView: View {
    let outcome: AddAccountOutcome
    let addAnother: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: Icons.succeeded)
                .font(.system(size: 64))
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            if outcome.signedInAgain {
                Text(ui: "Signed in again to \(outcome.account.email)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("addAccount.signedInAgain")
            } else {
                Text(ui: "Account added")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    Avatar(
                        name: outcome.account.displayName, email: outcome.account.email, size: 40,
                        colorIndex: outcome.account.colorIndex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.account.displayName)
                        Text(outcome.account.email)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            if !outcome.signedInAgain {
                VStack(spacing: 12) {
                    Button(action: done) {
                        Text(ui: "Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("addAccount.done")
                    Button(action: addAnother) {
                        Text(ui: "Add another account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("addAccount.another")
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
