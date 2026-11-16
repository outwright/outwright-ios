// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightSync
import SwiftUI

/// Adding an account: the address first, which goes to the sign-in of a provider that claims it;
/// otherwise name, password and the servers found, each editable; Connect signs in to both
/// servers before anything is kept.
struct AddAccountView: View {
    let app: AppModel
    @State private var model: AddAccountModel
    @State private var hasLookedUp = false
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
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel) {
        self.app = app
        _model = State(
            initialValue: AddAccountModel(
                store: app.store, secrets: app.sync.secrets, resolver: CloudflareDoH(),
                collections: { await DAVCollections.exist($0, at: $1, for: $2, password: $3) },
                probe: DAVDiscovery.wellKnownProbe))
        _providers = State(initialValue: app.addableProviders)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasLookedUp {
                        LabeledField("Email address") {
                            TextField(text: $model.email) { Text(verbatim: "") }
                                .emailEntry()
                                .accessibilityIdentifier("addAccount.email")
                                .disabled(true)
                        }
                    } else {
                        TextField(text: $model.email) { Text(ui: "Email address") }
                            .emailEntry()
                            .accessibilityIdentifier("addAccount.email")
                            .disabled(isLookingUp)
                    }
                } footer: {
                    if !hasLookedUp {
                        Text(ui: "Only the address's domain is looked up, to find its mail servers.")
                    }
                }
                if hasLookedUp {
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
                }
            }
            .navigationTitle(Text(ui: "Add account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        lookup?.cancel()
                        dismiss()
                    } label: {
                        Text(ui: "Cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLookingUp || model.isDiscovering || model.isConnecting || isSigningIn {
                        ProgressView()
                    } else if hasLookedUp {
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
        .onChange(of: model.email) { offersOwnServer = false }
        .onDisappear { lookup?.cancel() }
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
        }
        EndpointSection(title: "Incoming mail (IMAP)", endpoint: $model.imap, defaultPort: 993, id: "imap")
        EndpointSection(title: "Outgoing mail (SMTP)", endpoint: $model.smtp, defaultPort: 465, id: "smtp")
        Section {
            Toggle(isOn: $model.calendarOn) { Text(ui: "Sync calendar") }
                .accessibilityIdentifier("addAccount.calendarOn")
            if model.calendarOn {
                TextField(text: $model.calDAV) { Text(ui: "CalDAV address") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.calDAV")
            }
        } header: {
            Text(ui: "Calendar")
        }
        Section {
            Toggle(isOn: $model.contactsOn) { Text(ui: "Sync contacts") }
                .accessibilityIdentifier("addAccount.contactsOn")
            if model.contactsOn {
                TextField(text: $model.cardDAV) { Text(ui: "CardDAV address") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.cardDAV")
            }
        } header: {
            Text(ui: "Contacts")
        }
        Section {
            LabeledField("User name") {
                TextField(text: $model.user) { Text(verbatim: "") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.user")
            }
        } footer: {
            Text(ui: "The password is checked with both servers and kept in the keychain only when both accept it.")
        }
    }

    /// The hosts outside the address's domain, as a list for a sentence.
    private var hostsToAllow: String {
        model.hostsNeedingConfirmation.formatted(.list(type: .and))
    }

    private func connect() {
        Task {
            if let error = await attempt() {
                failure = error
                return
            }
            app.reloadAccounts()
            dismiss()
            Task { await app.accountAdded() }
        }
    }

    private var isSigningIn: Bool {
        providers.contains { $0.signIn.isSigningIn }
    }

    private func attempt() async -> AddAccountError? {
        do {
            _ = try await model.connect()
            return nil
        } catch {
            return error
        }
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
        hasLookedUp = true
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
        do throws(ProviderSignInError) {
            _ = try await signIn.addAccount(hint: hint)
        } catch {
            if case let .failed(text) = error { providerFailure = text }
            return false
        }
        app.reloadAccounts()
        dismiss()
        Task { await app.accountAdded() }
        return true
    }
}

/// Host, port and encryption of one server.
private struct EndpointSection: View {
    let title: LocalizedStringKey
    @Binding var endpoint: MailEndpoint?
    let defaultPort: UInt16
    /// The accessibility identifiers' middle part ("imap" or "smtp").
    let id: String

    var body: some View {
        Section {
            LabeledField("Server") {
                TextField(text: host) { Text(verbatim: "") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.\(id).host")
            }
            LabeledField("Port") {
                TextField(text: port) { Text(verbatim: "") }
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("addAccount.\(id).port")
            }
            Picker(selection: security) {
                Text(ui: "TLS").tag("tls")
                Text(ui: "STARTTLS").tag("startTLS")
            } label: {
                Text(ui: "Encryption")
            }
            .accessibilityIdentifier("addAccount.\(id).security")
        } header: {
            Text(ui: title)
        }
    }

    private var current: MailEndpoint {
        endpoint ?? MailEndpoint(host: "", port: defaultPort, security: "tls")
    }

    private var host: Binding<String> {
        Binding { current.host } set: { value in
            var next = current
            next.host = value.trimmingCharacters(in: .whitespaces).lowercased()
            endpoint = next
        }
    }

    private var port: Binding<String> {
        Binding { String(current.port) } set: { value in
            var next = current
            next.port = UInt16(value.filter(\.isNumber).prefix(5)) ?? 0
            endpoint = next
        }
    }

    private var security: Binding<String> {
        Binding { current.security } set: { value in
            var next = current
            next.security = value
            endpoint = next
        }
    }
}

/// A row with its name before the field, so a filled-in field still says what it is (#59).
private struct LabeledField<Field: View>: View {
    let label: LocalizedStringKey
    let field: Field

    init(_ label: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        LabeledContent {
            field
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(ui: label))
        } label: {
            Text(ui: label)
        }
    }
}
