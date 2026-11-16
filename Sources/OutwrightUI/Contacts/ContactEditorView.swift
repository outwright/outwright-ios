// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The contact editor sheet: ✕, the address book with its account, ✓; then the fields.
struct ContactEditorView: View {
    let app: AppModel
    let request: ContactEditorRequest
    @State private var model: ContactEditorModel
    @State private var failure: ContactEditError?
    @State private var savedID: ContactID?
    @State private var asksToDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, request: ContactEditorRequest) {
        self.app = app
        self.request = request
        _model = State(
            initialValue: ContactEditorModel(app: app, editing: request.editing, prefill: request.prefill))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    if let failure { ProblemBanner(text: Self.message(failure)) }
                    if model.isOverLimits {
                        ProblemBanner(
                            text: L10n.string(
                                """
                                This address book holds at most three email addresses, one mobile number and \
                                one address of each kind.
                                """))
                    }
                    nameCard
                    labeledCard(
                        "Phone", $model.details.phones, add: "Add phone", icon: "phone",
                        labels: model.phoneLabels(for:), canAdd: true, keyboard: .phone)
                    labeledCard(
                        "Email", $model.details.emails, add: "Add email", icon: "envelope",
                        labels: { _ in model.emailLabels }, canAdd: model.canAddEmail, keyboard: .email)
                    addressCards
                    noteCard
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.drawerBackground)
        // Swiping the sheet away would lose what is typed without asking.
        .interactiveDismissDisabled(model.hasChanges)
        .confirmationDialog(Text(ui: "Discard your changes?"), isPresented: $asksToDiscard, titleVisibility: .visible) {
            Button(role: .destructive) { close() } label: { Text(ui: "Discard changes") }
            Button(role: .cancel) {} label: { Text(ui: "Keep editing") }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { if model.hasChanges { asksToDiscard = true } else { close() } } label: {
                Image(systemName: Icons.close).font(.title3).frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text(ui: "Close"))
            bookPicker
            Spacer(minLength: 4)
            Button { save() } label: {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(model.canSave ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(!model.canSave)
            .accessibilityLabel(Text(ui: "Save"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// The book the contact goes to; a menu of the writable ones for a new contact.
    @ViewBuilder
    private var bookPicker: some View {
        if let chosen = model.chosen {
            if model.editing == nil && model.writableBooks.flatMap(\.books).count > 1 {
                Menu {
                    ForEach(model.writableBooks, id: \.account.id) { group in
                        Section(group.account.displayName) {
                            ForEach(group.books) { book in
                                Button { model.book = book.id } label: {
                                    if book.id == model.book {
                                        Label(book.name, systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: book.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    bookLabel(chosen.account, chosen.book, chevron: true)
                }
                .accessibilityLabel(Text(ui: "Address book"))
            } else {
                bookLabel(chosen.account, chosen.book, chevron: false)
            }
        }
    }

    private func bookLabel(_ account: Account, _ book: AddressBook, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            Avatar(name: account.displayName, email: account.email, size: 28, colorIndex: account.colorIndex)
            Text(verbatim: book.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
            if chevron { Image(systemName: "chevron.down").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Cards

    private var nameCard: some View {
        card {
            field("First name", $model.details.givenName)
            Divider()
            field("Last name", $model.details.familyName)
            Divider()
            field("Organization", $model.details.organization)
        }
    }

    private func field(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        TextField(text: text) { Text(ui: title) }
            .padding(14)
            .frame(minHeight: 44)
    }

    // swiftlint:disable:next function_parameter_count
    private func labeledCard(
        _ title: LocalizedStringKey, _ rows: Binding<[Labeled]>, add: LocalizedStringKey, icon: String,
        labels: @escaping (Int) -> [String], canAdd: Bool, keyboard: Entry
    ) -> some View {
        card {
            ForEach(rows.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(labels(index), id: \.self) { label in
                            Button { rows.wrappedValue[index].label = label } label: {
                                Text(verbatim: Self.title(label))
                            }
                        }
                    } label: {
                        Text(verbatim: Self.title(rows.wrappedValue[safe: index]?.label ?? ""))
                            .font(.subheadline).foregroundStyle(Theme.accent)
                            .frame(minWidth: 64, alignment: .leading)
                    }
                    TextField(
                        text: Binding(
                            get: { rows.wrappedValue[safe: index]?.value ?? "" },
                            set: {
                                if rows.wrappedValue.indices.contains(index) { rows.wrappedValue[index].value = $0 }
                            })
                    ) { Text(ui: title) }
                    .entry(keyboard)
                    removeButton { remove(rows, index) }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                Divider()
            }
            if canAdd {
                addButton(add, icon: icon) {
                    rows.wrappedValue.append(Labeled(label: labels(rows.wrappedValue.count).first ?? "", value: ""))
                }
            }
        }
    }

    @ViewBuilder
    private var addressCards: some View {
        ForEach(model.details.addresses.indices, id: \.self) { index in
            card {
                HStack {
                    Menu {
                        ForEach(model.addressLabels(for: index), id: \.self) { label in
                            Button { model.details.addresses[index].label = label } label: {
                                Text(verbatim: Self.title(label))
                            }
                        }
                    } label: {
                        Text(verbatim: Self.title(model.details.addresses[safe: index]?.label ?? ""))
                            .font(.subheadline).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    removeButton {
                        if model.details.addresses.indices.contains(index) { model.details.addresses.remove(at: index) }
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                Divider()
                place("Street", index, \.street)
                Divider()
                place("Postal code", index, \.postalCode)
                Divider()
                place("City", index, \.locality)
                Divider()
                place("Region", index, \.region)
                Divider()
                place("Country", index, \.country)
            }
        }
        if model.canAddAddress {
            card {
                addButton("Add address", icon: "mappin.and.ellipse") {
                    model.details.addresses.append(PostalAddress(label: model.newAddressLabel))
                }
            }
        }
    }

    private func place(
        _ title: LocalizedStringKey, _ index: Int, _ path: WritableKeyPath<PostalAddress, String>
    ) -> some View {
        TextField(
            text: Binding(
                get: { model.details.addresses[safe: index]?[keyPath: path] ?? "" },
                set: {
                    if model.details.addresses.indices.contains(index) {
                        model.details.addresses[index][keyPath: path] = $0
                    }
                })
        ) { Text(ui: title) }
        .padding(14)
        .frame(minHeight: 44)
    }

    private var noteCard: some View {
        card {
            TextField(text: $model.details.note, axis: .vertical) { Text(ui: "Note") }
                .lineLimit(2...8)
                .padding(14)
                .frame(minHeight: 44, alignment: .topLeading)
        }
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func addButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ModuleLabel(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
        }
        .foregroundStyle(Theme.accent)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.secondaryText).frame(width: 32, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ui: "Delete"))
    }

    private func remove(_ rows: Binding<[Labeled]>, _ index: Int) {
        if rows.wrappedValue.indices.contains(index) { rows.wrappedValue.remove(at: index) }
    }
}

extension ContactEditorView {
    private func save() {
        do {
            savedID = try model.save()
            returnToCard()
            dismiss()
        } catch {
            failure = error
        }
    }

    private func close() {
        returnToCard()
        dismiss()
    }

    /// An edit or an add-contact came from a card: back to it once the editor has gone.
    private func returnToCard() {
        guard request.editing != nil || request.prefill != nil else { return }
        if let savedID {
            app.pendingPerson = PersonRequest(contact: savedID)
        } else if let editing = request.editing {
            app.pendingPerson = PersonRequest(contact: editing)
        } else if let address = request.prefill {
            app.pendingPerson = PersonRequest(address: address)
        }
    }

    static func message(_ error: ContactEditError) -> String {
        switch error {
        case .noBook: L10n.string("There is no address book to save the contact in.")
        case .empty: L10n.string("Add a name, organization, phone number or email address.")
        case .store: L10n.string("The contact couldn't be saved. Try again.")
        }
    }

    /// The label as shown: the usual ones in the app's language, any other as it was written.
    static func title(_ label: String) -> String {
        switch label.lowercased() {
        case "mobile", "cell": L10n.string("Mobile")
        case "work": L10n.string("Work")
        case "home": L10n.string("Home")
        case "other": L10n.string("Other")
        case "": L10n.string("Label")
        default: label
        }
    }
}

/// What a field takes, for the keyboard.
enum Entry {
    case phone, email
}

extension View {
    fileprivate func entry(_ kind: Entry) -> some View {
        #if os(iOS)
        self.keyboardType(kind == .phone ? .phonePad : .emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

extension Array {
    /// The element at `index`, or nil outside the array.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
