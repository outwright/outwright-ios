// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightSync
import SwiftUI

/// Where Add account stands, which decides how it is left.
enum AddAccountPlacement {
    /// A sheet from the drawer's plus or an empty screen: Cancel closes it.
    case sheet
    /// The first account: nothing to go back to, so no Cancel.
    case firstRun
    /// A page of Settings: the back button leaves it.
    case pushed
}

/// Add account as a sheet or the first run's full screen, in a navigation stack of its own.
struct AddAccountSheet: View {
    let app: AppModel
    let placement: AddAccountPlacement

    var body: some View {
        NavigationStack {
            AddAccountView(app: app, placement: placement)
        }
        .interactiveDismissDisabled(placement == .firstRun && app.accounts.isEmpty)
    }
}

/// Adding an account: the address first, which goes to the sign-in of a provider that claims it;
/// otherwise name, password and user name, with the servers found behind "Server settings" (open
/// when none was found); Connect signs in to both servers before anything is kept. The address stays
/// editable, and editing it looks it up again. It ends on `AccountAddedView`.
struct AddAccountView: View {
    let app: AppModel
    let placement: AddAccountPlacement
    @State private var model: AddAccountModel
    /// Continue is under way: asking the providers whether the address is theirs, then their
    /// sign-in or the own server's lookup. Cancelled when the screen goes.
    @State private var lookup: Task<Void, Never>?
    @State private var isLookingUp = false
    /// A provider claimed the address and its sign-in did not end in an account: the owner may
    /// set it up with the mail server instead.
    @State private var offersOwnServer = false
    @State private var failure: AddAccountError?
    /// Connect was pressed with a server outside the address's domain: asked before the password goes.
    @State private var isAskingToAllow = false
    /// The build's providers' sign-ins, in the composition's order.
    @State private var providers: [(provider: any AccountProvider, signIn: any ProviderSignIn)]
    @State private var providerFailure: String?
    /// The account the flow ended with, and whether it was only signed in again.
    @State private var outcome: AddAccountOutcome?
    /// The pause on "Signed in again" before the screen closes.
    @State private var closing: Task<Void, Never>?
    @State private var showsServers = false
    @State private var showsHelp = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, placement: AddAccountPlacement) {
        self.app = app
        self.placement = placement
        _model = State(initialValue: Self.newModel(app))
        _providers = State(initialValue: app.addableProviders)
    }

    private static func newModel(_ app: AppModel) -> AddAccountModel {
        AddAccountModel(
            store: app.store, secrets: app.sync.secrets, resolver: CloudflareDoH(),
            collections: { await DAVCollections.exist($0, at: $1, for: $2, password: $3) },
            probe: DAVDiscovery.wellKnownProbe)
    }

    var body: some View {
        Group {
            if let outcome {
                AccountAddedView(outcome: outcome, addAnother: addAnother, done: { dismiss() })
            } else {
                form
            }
        }
        .navigationTitle(Text(ui: "Add account"))
        .inlineNavigationTitle()
        .navigationBarBackButtonHidden(outcome != nil)
        .onChange(of: model.email) { offersOwnServer = false }
        .onDisappear {
            lookup?.cancel()
            closing?.cancel()
        }
    }

    private var form: some View {
        Form {
            if placement == .firstRun, !model.hasLookedUp { FirstRunBringSection(app: app) }
            Section {
                TextField(text: $model.email) { Text(ui: "Email address") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.email")
                    .disabled(isLookingUp)
            } footer: {
                if model.hasLookedUp, model.discoveryFailed {
                    Text(ui: "Couldn't find the servers for this address. Enter them below.")
                } else if !model.hasLookedUp {
                    Text(ui: "Only the address's domain is looked up, to find its mail servers.")
                }
            }
            if model.hasLookedUp {
                details
            } else {
                if offersOwnServer {
                    Section {
                        Button { lookUpOwnServer() } label: { Text(ui: "Set up with the mail server instead") }
                            .disabled(isSigningIn || isLookingUp)
                            .accessibilityIdentifier("addAccount.ownServer")
                    }
                }
                ForEach(providers.indices, id: \.self) { index in
                    let entry = providers[index]
                    Section {
                        Button { add(with: entry.signIn) } label: { Text(entry.provider.addTitle) }
                            .disabled(isSigningIn || isLookingUp)
                            .accessibilityIdentifier(entry.provider.addIdentifier)
                    } footer: {
                        if let note = entry.provider.addNote {
                            Text(note)
                        }
                    }
                }
                if placement == .firstRun { FirstRunRestoreSection(app: app) }
            }
        }
        .toolbar {
            if placement == .firstRun {
                // No Cancel here, so Help is reached from this screen itself.
                ToolbarItem(placement: .cancellationAction) {
                    Button { showsHelp = true } label: { Image(systemName: Icons.help) }
                        .accessibilityLabel(Text(ui: "Help"))
                        .accessibilityIdentifier("addAccount.help")
                }
            }
            if placement == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        lookup?.cancel()
                        dismiss()
                    } label: {
                        Text(ui: "Cancel")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isLookingUp || model.isDiscovering || model.isConnecting || isSigningIn {
                    ProgressView()
                } else if model.hasLookedUp {
                    Button {
                        if model.needsServerConfirmation {
                            isAskingToAllow = true
                        } else {
                            connect()
                        }
                    } label: {
                        Text(ui: "Connect")
                    }
                    .disabled(model.password.isEmpty)
                } else {
                    Button { lookUp() } label: {
                        Text(ui: "Continue")
                    }
                    .disabled(!model.isAddressValid)
                }
            }
        }
        .sheet(isPresented: $showsHelp) { HelpView().presentationDetents([.medium, .large]) }
        .alert(
            Text(ui: "Allow \(hostsToAllow)?"), isPresented: $isAskingToAllow
        ) {
            Button {
                model.confirmServers()
                connect()
            } label: {
                Text(ui: "Allow")
            }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: {
            Text(
                ui: """
                    The servers for \(model.email) are at \(hostsToAllow), not at \(model.domain ?? ""). \
                    Your password is sent there. Allow only servers you know.
                    """)
        }
        .alert(
            Text(ui: "The account was not added"), isPresented: Binding(presenting: $failure), presenting: failure
        ) { _ in
            Button { failure = nil } label: { Text(ui: "OK") }
        } message: { error in
            Text(ui: Self.explanation(error))
        }
        .alert(
            Text(ui: "The account was not added"), isPresented: .constant(providerFailure != nil),
            presenting: providerFailure
        ) { _ in
            Button { providerFailure = nil } label: { Text(ui: "OK") }
        } message: { text in
            Text(text)
        }
    }

    @ViewBuilder private var details: some View {
        Section {
            LabeledField("Your name") {
                TextField(text: $model.name) { Text(verbatim: "") }
                    .accessibilityIdentifier("addAccount.name")
            }
            LabeledField("Password") {
                SecureField(text: $model.password) { Text(verbatim: "") }
                    .textContentType(.password)
                    .accessibilityIdentifier("addAccount.password")
            }
            LabeledField("User name") {
                TextField(text: $model.user) { Text(verbatim: "") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.user")
            }
        } footer: {
            Text(ui: "The password is checked with both servers and kept in the keychain only when both accept it.")
        }
        if model.discoveryFailed {
            Section { serverRows }
        } else {
            Section {
                DisclosureGroup(isExpanded: $showsServers) {
                    serverRows
                } label: {
                    Text(ui: "Server settings")
                }
                .accessibilityIdentifier("addAccount.serverSettings")
            }
        }
    }

    /// The servers and the DAV addresses: shown open when none was found, else behind "Server settings".
    @ViewBuilder private var serverRows: some View {
        ServerGroup(title: "Incoming mail (IMAP)")
        EndpointRows(endpoint: $model.imap, defaultPort: 993, id: "imap")
        ServerGroup(title: "Outgoing mail (SMTP)")
        EndpointRows(endpoint: $model.smtp, defaultPort: 465, id: "smtp")
        ServerGroup(title: "Calendar")
        Toggle(isOn: $model.calendarOn) { Text(ui: "Sync calendar") }
            .accessibilityIdentifier("addAccount.calendarOn")
        if model.calendarOn {
            TextField(text: $model.calDAV) { Text(ui: "CalDAV address") }
                .emailEntry()
                .accessibilityIdentifier("addAccount.calDAV")
        }
        ServerGroup(title: "Contacts")
        Toggle(isOn: $model.contactsOn) { Text(ui: "Sync contacts") }
            .accessibilityIdentifier("addAccount.contactsOn")
        if model.contactsOn {
            TextField(text: $model.cardDAV) { Text(ui: "CardDAV address") }
                .emailEntry()
                .accessibilityIdentifier("addAccount.cardDAV")
        }
    }

    /// The hosts outside the address's domain, as a list for a sentence.
    private var hostsToAllow: String {
        model.hostsNeedingConfirmation.formatted(.list(type: .and))
    }

    private func connect() {
        Task {
            let added: Account
            do throws(AddAccountError) {
                added = try await model.connect()
            } catch {
                failure = error
                return
            }
            finish(added, signedInAgain: false)
        }
    }

    private var isSigningIn: Bool {
        providers.contains { $0.signIn.isSigningIn }
    }

    static func explanation(_ error: AddAccountError) -> LocalizedStringKey {
        switch error {
        case .incomplete: "Fill in the address, the password and both servers."
        case .alreadyAdded: "This address is already on the phone."
        case .serversNotConfirmed: "Confirm the servers before the password is sent to them."
        case .signIn(.imap(.authenticationFailed)), .signIn(.smtp(.authenticationFailed)):
            "The server did not accept the user name and password."
        case .signIn(.imap(.startTLSNotOffered)), .signIn(.smtp(.startTLSNotOffered)):
            "The server does not offer encryption, so nothing was sent."
        case .signIn(.smtp): "The outgoing server could not be signed in to."
        case .signIn: "The incoming server could not be reached or signed in to."
        case .keychain: "The password could not be kept in the keychain."
        case .store: "The account could not be saved on this phone."
        }
    }
}

/// Continue and the providers' buttons.
extension AddAccountView {
    /// Continue: the sign-in of the provider whose address it is, or else the owner's own
    /// server's lookup. The address is the one Continue was pressed for.
    private func lookUp() {
        let address = model.email
        run {
            let claimed = await AppModel.signIn(claiming: address, among: providers, resolver: model.resolver)
            guard !Task.isCancelled else { return }
            guard let claimed else {
                await discoverOwnServer()
                return
            }
            if await !addAccount(with: claimed, hint: address) {
                offersOwnServer = true
            }
        }
    }

    /// The address goes to the owner's own server after all.
    private func lookUpOwnServer() {
        run { await discoverOwnServer() }
    }

    private func discoverOwnServer() async {
        await model.discover()
        guard !Task.isCancelled else { return }
        offersOwnServer = false
    }

    /// A provider's own button: no address goes with it, since none was claimed.
    private func add(with signIn: any ProviderSignIn) {
        run { _ = await addAccount(with: signIn, hint: nil) }
    }

    /// One step of Continue at a time, kept so leaving the screen cancels it.
    private func run(_ step: @escaping @MainActor () async -> Void) {
        lookup?.cancel()
        lookup = Task {
            isLookingUp = true
            await step()
            // A step cancelled for the next one leaves the spinner to it.
            if !Task.isCancelled { isLookingUp = false }
        }
    }

    /// Whether the sign-in added the account; the screen is closed when it did.
    private func addAccount(with signIn: any ProviderSignIn, hint: String?) async -> Bool {
        let added: Account
        do throws(ProviderSignInError) {
            added = try await signIn.addAccount(hint: hint)
        } catch {
            if case let .failed(text) = error { providerFailure = text }
            return false
        }
        // A provider that already has the address only signs it in again.
        finish(added, signedInAgain: app.accounts.contains { $0.id == added.id })
        return true
    }

    /// The flow's end: the account is on the phone. A new one is told and its mail read; one signed
    /// in again is told for a moment and the screen closes (its notifications stay as they were).
    private func finish(_ account: Account, signedInAgain: Bool) {
        app.reloadAccounts()
        outcome = AddAccountOutcome(account: account, signedInAgain: signedInAgain)
        if signedInAgain {
            closing = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                dismiss()
            }
            Task { await app.refresh() }
        } else {
            Task { await app.accountAdded(account) }
        }
    }

    /// "Add another account": the form starts over.
    private func addAnother() {
        lookup?.cancel()
        model = Self.newModel(app)
        offersOwnServer = false
        showsServers = false
        outcome = nil
    }
}
