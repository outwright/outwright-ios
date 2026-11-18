// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The compose sheet: what a reply, forward or draft starts from is read (and opened) away from the
/// main actor first, its body fetched when it isn't on the phone, then the message being written
/// shows. When the body can't be had, it says so and never opens a cut copy.
struct ComposeSheet: View {
    let app: AppModel
    let request: ComposeRequest
    @State private var phase = Phase.loading
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready(ComposeModel)
        case unavailable
    }

    var body: some View {
        switch phase {
        case .ready(let model):
            ComposeView(app: app, model: model)
        case .unavailable:
            VStack(spacing: 0) {
                EditorHeader(close: { dismiss() }, confirm: nil, confirmEnabled: false, middle: { EmptyView() })
                Spacer()
                Text(ui: "This message couldn't be loaded.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .task {
                    let language = Bundle.module.preferredLocalizations.first ?? "en"
                    let started = await ComposeModel.start(
                        request: request, store: app.store, accounts: app.writableAccounts,
                        accountInView: app.accountInView?.id,
                        defaultAccount: app.defaultAccountID, locale: Locale(identifier: language),
                        protectionScreens: app.modules.protectionScreens, fetchBody: { await app.fetchBody($0) })
                    phase = started.map(Phase.ready) ?? .unavailable
                }
        }
    }
}
