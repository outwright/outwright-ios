// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// The compose sheet: ✕, the sending account and send; To (Cc and Bcc behind the chevron),
/// Subject, the body, and a toolbar over the keyboard.
struct ComposeView: View {
    let app: AppModel
    @State private var model: ComposeModel
    @State private var selection = AttributedTextSelection()
    @State private var showsCopies = false
    @State private var typed: [Field: String] = [:]
    @State private var failure: ComposeError?
    /// Recipients who can't receive a protected message: the owner is asked what to do.
    @State private var choosing: [Address] = []
    /// Sending stopped because the message can't be protected from the account yet.
    @State private var unprotectable = false
    /// The recipients a key is being added for.
    @State private var addingKeys: [Address] = []
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The folded line was tapped: the fields show, and the subject takes the keyboard once it is there.
    @State private var unfolds = false

    enum Field: Hashable {
        case to, cc, bcc, subject, body
    }

    init(app: AppModel, model: ComposeModel) {
        self.app = app
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.onChange(of: focus) { _, field in if field != .body { unfolds = false } }
            Divider()
            if foldsFields {
                FoldedFields(recipients: model.to + model.cc + model.bcc, subject: model.subject) { unfold() }
                Divider()
            } else {
                fields
            }
            if let note = model.protectionNote(typed: typedAddresses) {
                ProtectionNoteRow(note: note)
                Divider()
            }
            if let suggestions = currentSuggestions, !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions) { add($0) }
            } else {
                editor
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            ComposeToolbar(model: model, text: $model.body, selection: $selection, showsCopies: $showsCopies)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .onAppear { focus = model.to.isEmpty ? .to : .body }
        .askingAboutProtection(
            model: model, app: app,
            questions: ProtectionQuestions(choosing: $choosing, unprotectable: $unprotectable, addingKeys: $addingKeys),
            send: send)
        // Swiping the sheet away would skip the question below when the draft can't be kept.
        .interactiveDismissDisabled(model.hasChanges && !model.isFinished)
        .onDisappear { app.composeGone(model) }
        // The app may not come back: what is written is kept, and the message stays open.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.keepInTheBackground() }
        }
        .alert(
            Text(ui: "The draft was not kept"), isPresented: Binding(presenting: $model.keepFailure),
            presenting: model.keepFailure
        ) { _ in
            Button(role: .destructive) {
                model.keepFailure = nil
                model.discard()
                dismiss()
            } label: {
                Text(ui: "Discard")
            }
            Button(role: .cancel) { model.keepFailure = nil } label: { Text(ui: "Keep writing") }
        } message: { error in
            Text(ui: Self.explanation(error))
        }
        .alert(
            Text(ui: "The message was not sent"), isPresented: Binding(presenting: $failure), presenting: failure
        ) { _ in
            Button { failure = nil } label: { Text(ui: "OK") }
        } message: { error in
            Text(ui: Self.explanation(error))
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                closeSheet()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text(ui: "Close"))
            accountMenu
            Spacer(minLength: 4)
            Button {
                send()
            } label: {
                Image(systemName: "paperplane")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(canSend ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(!canSend || model.isSending)
            .accessibilityLabel(Text(ui: "Send"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var accountMenu: some View {
        if model.accounts.count < 2 {
            accountLabel
        } else {
            Menu {
                ForEach(model.accounts) { account in
                    Button {
                        model.from = account.id
                    } label: {
                        if account.id == model.from {
                            Label(account.email, systemImage: "checkmark")
                        } else {
                            Text(account.email)
                        }
                    }
                }
            } label: {
                accountLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "From"))
        }
    }

    private var accountLabel: some View {
        HStack(spacing: 12) {
            if let account = model.account {
                Avatar(name: account.displayName, email: account.email, size: 36, colorIndex: account.colorIndex)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(model.account?.email ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch model.purpose {
        case .new: "New message"
        case .reply: "Reply (title)"
        case .forward: "Forward (title)"
        }
    }

    /// To, Cc and Bcc, and the subject.
    @ViewBuilder private var fields: some View {
        RecipientField(
            label: "To:", addresses: $model.to, typing: typing(.to), focus: $focus, field: .to, keys: model.keyStates
        ) {
            Button {
                withAnimation(.snappy) { showsCopies.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(showsCopies ? 180 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "Cc and Bcc"))
        }
        if showsCopies || !model.cc.isEmpty || !model.bcc.isEmpty {
            Divider()
            RecipientField(
                label: "Cc:", addresses: $model.cc, typing: typing(.cc), focus: $focus, field: .cc,
                keys: model.keyStates
            ) {
                EmptyView()
            }
            Divider()
            RecipientField(
                label: "Bcc:", addresses: $model.bcc, typing: typing(.bcc), focus: $focus, field: .bcc,
                keys: model.keyStates
            ) {
                EmptyView()
            }
        }
        Divider()
        subjectRow
            .onAppear { if unfolds { focus = .subject } }
        Divider()
    }

    private var subjectRow: some View {
        HStack(spacing: 6) {
            Text(ui: "Subject:")
                .foregroundStyle(.secondary)
            TextField(text: $model.subject) { EmptyView() }
                .focused($focus, equals: .subject)
                .accessibilityIdentifier("compose.subject")
                .submitLabel(.next)
                .onSubmit { focus = .body }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .frame(minHeight: 50)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if !model.attachments.isEmpty {
                AttachmentChips(model: model)
            }
            TextEditor(text: $model.body, selection: $selection)
                .focused($focus, equals: .body)
                .accessibilityIdentifier("compose.body")
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.top, 6)
        }
    }
}

extension ComposeView {
    // MARK: - Behaviour

    /// The addresses typed in the recipient lines that are not yet recipients.
    private var typedAddresses: [Address] {
        [Field.to, .cc, .bcc].flatMap { RecipientParser.split(typed[$0] ?? "").addresses }
    }

    private func typing(_ field: Field) -> Binding<String> {
        Binding { typed[field] ?? "" } set: { typed[field] = $0 }
    }

    private var canSend: Bool {
        !(model.to + model.cc + model.bcc).isEmpty
            || typed.values.contains { !RecipientParser.split($0).addresses.isEmpty }
    }

    private var currentSuggestions: [Address]? {
        guard let focus, [Field.to, .cc, .bcc].contains(focus) else { return nil }
        let text = (typed[focus] ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : model.suggestions(for: text)
    }

    private func add(_ address: Address) {
        switch focus {
        case .cc: model.cc.append(address)
        case .bcc: model.bcc.append(address)
        default: model.to.append(address)
        }
        if let focus { typed[focus] = "" }
    }

    /// Keeps the draft and closes; when it can't be kept the sheet stays and asks.
    private func closeSheet() {
        if model.closeAsked() { dismiss() }
    }

    private func send(choice: ProtectionChoice = .none) {
        choosing = []
        var lines: [RecipientList: String] = [:]
        for (field, text) in typed {
            switch field {
            case .to: lines[.to] = text
            case .cc: lines[.cc] = text
            case .bcc: lines[.bcc] = text
            case .subject, .body: break
            }
        }
        Task {
            do throws(ComposeError) {
                // What is still typed in a line goes too; anything in it that isn't an address stops the send.
                if app.modules.protectionUI == nil {
                    try model.send(typed: lines, choice: choice)
                } else {
                    try await model.send(afterLookupOf: lines, choice: choice)
                }
                typed = [:]
                dismiss()
                await app.sync.refreshAll()
            } catch {
                if case .needsProtectionChoice(let missing) = error {
                    typed = [:]
                    choosing = missing
                } else if error == .protectionUnavailable {
                    typed = [:]
                    unprotectable = true
                } else if error != .alreadySending {
                    failure = error
                }
            }
        }
    }
}

extension ComposeView {
    static func explanation(_ error: ComposeError) -> LocalizedStringKey {
        switch error {
        case .noRecipients: "Add at least one recipient."
        case .noDraftsFolder: "The account's folders have not been read yet. Refresh and try again."
        case .tooLarge: "The message is too large."
        case .notWritable: "The message could not be written. Check its recipients."
        case .store: "The message could not be saved on this phone."
        case .notAnAddress(let entry): "\"\(entry)\" is not an email address."
        case .needsProtectionChoice: "Some recipients can't receive encrypted mail."
        case .protectionUnavailable: "This message can't be encrypted from this account yet."
        case .alreadySending: "The message is already being sent."
        }
    }
}

extension ComposeView {
    /// On a phone lying on its side the keyboard leaves little height: while the text is written, the
    /// recipients and subject fold into one line, which unfolds them when tapped.
    fileprivate var foldsFields: Bool { verticalSizeClass == .compact && focus == .body && !unfolds }

    /// Shows the fields, then moves the keyboard to the subject: a field can only take it once it is shown.
    fileprivate func unfold() {
        unfolds = true
    }
}

/// The compose sheet: what a reply, forward or draft starts from is read (and opened) away from the
/// main actor first, then the message being written shows.
struct ComposeSheet: View {
    let app: AppModel
    let request: ComposeRequest
    @State private var model: ComposeModel?

    var body: some View {
        if let model {
            ComposeView(app: app, model: model)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .task {
                    let language = Bundle.module.preferredLocalizations.first ?? "en"
                    model = await ComposeModel.make(
                        request: request, store: app.store, accounts: app.writableAccounts,
                        accountInView: app.accountInView?.id, locale: Locale(identifier: language),
                        protectionUI: app.modules.protectionUI)
                }
        }
    }
}
