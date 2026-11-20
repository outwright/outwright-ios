// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

/// What the empty Mail, Calendar and Contacts show with no account: the way in to Add account, to
/// bringing the setup straight from another device, and to restoring a setup file.
struct NoAccountView: View {
    let app: AppModel
    let icon: String
    let message: LocalizedStringKey
    @State private var isPicking = false

    var body: some View {
        ContentUnavailableView {
            Label { Text(ui: "No account") } icon: { Image(systemName: icon) }
        } description: {
            Text(ui: message)
        } actions: {
            Button { app.isAddingAccount = true } label: { Text(ui: "Add account") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("noAccount.add")
            Text(ui: "Already use Outwright on another device?")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 8)
            Button { app.isBringingSetup = true } label: { Text(ui: "Bring my setup from another device") }
                .accessibilityIdentifier("noAccount.bringSetup")
            Button { isPicking = true } label: { Text(ui: "Import from a file") }
                .accessibilityIdentifier("noAccount.restore")
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.outwrightSetup, .data]) { result in
            guard case .success(let url) = result else { return }
            app.openSetupFile(url)
        }
    }
}
