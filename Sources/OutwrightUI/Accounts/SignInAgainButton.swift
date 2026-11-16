// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightSync
import SwiftUI

/// "Sign in again" for an OAuth account whose sign-in is gone: its provider's sheet, as when
/// adding it; on success its sync resumes. Not shown when the build lacks the provider.
struct SignInAgainButton: View {
    let app: AppModel
    let account: Account
    @State private var model: (any ProviderSignIn)?
    @State private var failure: String?

    init(app: AppModel, account: Account) {
        self.app = app
        self.account = account
        _model = State(initialValue: app.signIn(for: account))
    }

    var body: some View {
        if let model {
            Group {
                if model.isSigningIn {
                    ProgressView()
                } else {
                    Button { signIn(model) } label: { Text(ui: "Sign in again") }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("problem.signInAgain")
                }
            }
            .alert(
                Text(ui: "Not signed in"), isPresented: .constant(failure != nil), presenting: failure
            ) { _ in
                Button { failure = nil } label: { Text(ui: "OK") }
            } message: { text in
                Text(text)
            }
        }
    }

    private func signIn(_ model: any ProviderSignIn) {
        Task {
            do throws(ProviderSignInError) {
                try await model.signInAgain(account)
            } catch {
                if case let .failed(text) = error { failure = text }
                return
            }
            await app.refresh()
        }
    }
}
