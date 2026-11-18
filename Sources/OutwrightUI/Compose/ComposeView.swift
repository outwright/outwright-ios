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
    /// The account is being set up to encrypt.
    @State private var settingUp = false
    /// The recipient whose changed key is being looked at.
    @State private var personKey: String?
    /// ✕ with changes: Delete draft, Save draft or Cancel.
    @State private var askingClose = false
    /// Delete draft was refused: the message stays open and says why.
    @State private var deleteFailure: ComposeError?
    /// Where the sending account is set up to encrypt, asked once per account; nil: nothing to set up.
    @State private var setup: AnyView?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The folded line was tapped: the fields show, and the subject takes the keyboard once it is there.
    @State private var unfolds = false
    @ScaledMetric(relativeTo: .title3) private var chevronBox: CGFloat = 44

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
            if model.originalNotQuoted {
                NotQuotedRow()
                Divider()
            }
            if let note = model.protectionNote(typed: typedAddresses) {
                ProtectionNoteRow(note: note, setUp: setUp)
                Divider()
            }
            if let notice = model.protection?.notice, !model.hasCalendar {
                ProtectionNoticeRow(text: notice)
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
            ComposeToolbar(model: model, text: $model.body, selection: $selection, setUp: setUp)
                // The row has to fit the phone's width: symbols and buttons stop growing together here.
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .onAppear { focus = model.to.isEmpty ? .to : .body }
        // Writing starts at the top, above the signature, not where the editor puts the cursor (the end).
        .onChange(of: focus, initial: true) { _, field in
            guard field == .body, let start = model.cursorOnEntering else { return }
            let chars = model.body.characters
            let point = chars.index(chars.startIndex, offsetBy: start, limitedBy: chars.endIndex) ?? chars.endIndex
            selection = AttributedTextSelection(insertionPoint: point)
        }
        .task(id: model.from) { setup = model.account.flatMap { model.protectionUI?.accountSetup(for: $0) } }
        .askingAboutProtection(
            model: model, app: app,
            questions: ProtectionQuestions(
                choosing: $choosing, unprotectable: $unprotectable, addingKeys: $addingKeys, settingUp: $settingUp,
                personKey: $personKey, setup: setup),
            send: send)
        .confirmationDialog(Text(ui: "Keep this draft?"), isPresented: $askingClose, titleVisibility: .hidden) {
            Button(role: .destructive) {
                Task {
                    do throws(ComposeError) {
                        try await model.discardDraft()
                        dismiss()
                    } catch {
                        deleteFailure = error
                    }
                }
            } label: {
                Text(ui: "Delete draft")
            }
            Button { closeSheet() } label: { Text(ui: "Save draft") }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        }
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
            Text(ui: "The draft was not deleted"), isPresented: Binding(presenting: $deleteFailure),
            presenting: deleteFailure
        ) { _ in
            Button { deleteFailure = nil } label: { Text(ui: "OK") }
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
        EditorHeader(
            close: { closeTapped() }, confirm: { send() }, confirmEnabled: canSend && !model.isSending,
            confirmSymbol: Icons.send, confirmLabel: "Send", middle: { FromMenu(model: model) }
        )
    }

    /// To, Cc and Bcc, and the subject.
    @ViewBuilder private var fields: some View {
        RecipientField(
            label: "To:", addresses: $model.to, typing: typing(.to), focus: $focus, field: .to, keys: model.keyStates,
            showKey: showKey, add: { model.add($0, to: .to) }, next: { focus = showsCopyLines ? .cc : .subject },
            trailing: {
                Button {
                    withAnimation(.snappy) { showsCopies.toggle() }
                } label: {
                    Image(systemName: Icons.unfolded)
                        .rotationEffect(.degrees(showsCopies ? 180 : 0))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: chevronBox, height: chevronBox)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ui: "Cc and Bcc"))
            }
        )
        if showsCopyLines {
            Divider()
            RecipientField(
                label: "Cc:", addresses: $model.cc, typing: typing(.cc), focus: $focus, field: .cc,
                keys: model.keyStates, showKey: showKey, add: { model.add($0, to: .cc) }, next: { focus = .bcc },
                trailing: { EmptyView() })
            Divider()
            RecipientField(
                label: "Bcc:", addresses: $model.bcc, typing: typing(.bcc), focus: $focus, field: .bcc,
                keys: model.keyStates, showKey: showKey, add: { model.add($0, to: .bcc) }, next: { focus = .subject },
                trailing: { EmptyView() })
        }
        Divider()
        subjectRow
            .onAppear { if unfolds { focus = .subject } }
        Divider()
    }

    private var subjectRow: some View {
        HStack(spacing: 6) {
            Text(ui: "Subject:")
                .foregroundStyle(Theme.secondaryText)
                // The label keeps its word; the field takes what is left.
                .fixedSize()
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
            TextEditor(text: bodyText, selection: $selection)
                .focused($focus, equals: .body)
                .accessibilityIdentifier("compose.body")
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.top, 6)
            if let quote = model.quoted {
                QuotedOriginalView(quote: quote)
            }
        }
    }
}

extension ComposeView {
    // MARK: - Behaviour

    /// The body as typed, with Return in a bulleted or numbered line going on with the list.
    private var bodyText: Binding<AttributedString> {
        Binding {
            model.body
        } set: { typed in
            guard let edit = ListEditing.continued(old: model.body, new: typed) else {
                model.body = typed
                return
            }
            model.body = edit.text
            let chars = edit.text.characters
            let cursor =
                chars.index(chars.startIndex, offsetBy: edit.cursor, limitedBy: chars.endIndex) ?? chars.endIndex
            selection = AttributedTextSelection(insertionPoint: cursor)
        }
    }

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
        case .cc: model.add([address], to: .cc)
        case .bcc: model.add([address], to: .bcc)
        default: model.add([address], to: .to)
        }
        if let focus { typed[focus] = "" }
    }

    /// Cc and Bcc show: opened with the chevron, or holding someone.
    private var showsCopyLines: Bool {
        showsCopies || !model.cc.isEmpty || !model.bcc.isEmpty
    }

    /// ✕: closes at once when nothing changed, else asks whether to delete or save the draft.
    private func closeTapped() {
        switch model.closeChoice {
        case .close: closeSheet()
        case .ask: askingClose = true
        }
    }

    /// Keeps the draft and closes; when it can't be kept the sheet stays and asks.
    private func closeSheet() {
        if model.closeAsked() { dismiss() }
    }

    /// Opens where the account is set up to encrypt; nil when the build has nothing to set up.
    private var setUp: (() -> Void)? {
        setup == nil ? nil : { settingUp = true }
    }

    /// Opens a recipient's key from their chip; nil without a protection.
    private var showKey: ((String) -> Void)? {
        guard model.protectionUI != nil else { return nil }
        return { personKey = $0 }
    }

    /// What is still typed in each recipient line.
    private var typedLines: [RecipientList: String] {
        var lines: [RecipientList: String] = [:]
        for (field, text) in typed {
            switch field {
            case .to: lines[.to] = text
            case .cc: lines[.cc] = text
            case .bcc: lines[.bcc] = text
            case .subject, .body: break
            }
        }
        return lines
    }

    private func send(choice: ProtectionChoice = .none) {
        choosing = []
        let lines = typedLines
        Task {
            do throws(ComposeError) {
                // What is still typed in a line goes too; anything in it that isn't an address stops the send.
                if model.protectionUI == nil {
                    try model.send(typed: lines, choice: choice)
                } else {
                    try await model.send(afterLookupOf: lines, choice: choice)
                }
                typed = [:]
                dismiss()
                if let draft = model.draftID {
                    await app.sent(draft)
                } else {
                    await app.sync.refreshAll()
                }
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
