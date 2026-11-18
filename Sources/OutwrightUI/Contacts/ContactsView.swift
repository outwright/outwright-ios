// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The Contacts tab: the header with search and plus, the list in letter sections with the alphabet on
/// the right. Search opens its field under the header; the address books are chosen in the drawer.
/// In one column a contact's card is pushed over the list; in two it stands beside it.
struct ContactsView: View {
    @ScaledMetric(relativeTo: .title3) private var fieldHeight: CGFloat = 48
    let app: AppModel
    @Bindable var model: ContactsModel
    var calendar: CalendarModel?
    var wide = WideContext()
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    /// The search button was just tapped: the field takes focus when it appears, not when it comes back.
    @State private var focusesSearch = false
    @Environment(\.horizontalSizeClass) private var widthClass
    @State private var listWidth: CGFloat = 0

    /// Wide enough for the list and the card side by side.
    private var isWide: Bool { widthClass == .regular }

    var body: some View {
        Group {
            if isWide {
                WideSplit(
                    layout: wide.layout, expands: false, state: wide.state, width: wide.width,
                    sidebar: { sidebar },
                    content: {
                        listColumn
                            .standsOnTabCapsule()
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { listWidth = $0 }
                    },
                    detail: {
                        card.besideTabCapsule(from: listWidth + 1)
                    })
            } else {
                NavigationStack(path: $model.path) {
                    listColumn
                        #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                        #endif
                        // As for the mail list: the tabs come and go with a swipe back, not after it.
                        .onAppear {
                            model.isListInView = PushedList.inViewOnAppear(
                                path: model.path, tabReturning: model.isTabReturning)
                            model.isTabReturning = false
                        }
                        .onDisappear { model.isListInView = false }
                        .navigationDestination(for: ContactID.self) { id in
                            PersonCardView(
                                app: app, request: PersonRequest(contact: id, account: stored(id)?.accountID),
                                presentation: .pushed)
                        }
                }
                .onChange(of: model.path) { _, now in if !now.isEmpty { model.isListInView = false } }
            }
        }
        .task { await model.observe() }
        // A turn between one column and two keeps the open card open.
        .onChange(of: isWide) { _, wide in carry(wide: wide) }
    }

    /// The address books beside the list on an iPad.
    @ViewBuilder private var sidebar: some View {
        if let drawer = wide.drawer, let calendar {
            SidebarColumn(app: app, model: drawer, calendar: calendar, contacts: model, showsAccounts: false)
        }
    }

    @ViewBuilder private var card: some View {
        if let id = model.selected, let contact = stored(id) {
            PersonCardView(
                app: app, request: PersonRequest(contact: id, account: contact.accountID), presentation: .pane)
                .id(id)
        } else {
            ContentUnavailableView {
                Label { Text(ui: "No contact selected") } icon: { Image(systemName: Icons.contacts) }
            }
            .background(Theme.drawerBackground)
        }
    }

    /// The card pushed in one column becomes the selection in two, and the other way round. A card
    /// opened from elsewhere (an address in a message) stays a sheet.
    private func carry(wide: Bool) {
        let carried = PaneSelection.carry(path: model.path, selected: model.selected, wide: wide)
        model.path = carried.path
        model.selected = carried.selected
    }

    /// The contact, from the list or else the store (a search may hide it from the list).
    private func stored(_ id: ContactID) -> Contact? {
        model.sections.lazy.flatMap(\.contacts).first { $0.id == id } ?? (try? app.store.contact(id)) ?? nil
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            header
            AttentionBanners(app: app)
            if model.failed {
                ProblemBanner(text: L10n.string("Contacts couldn't be read. Try again."))
            }
            if model.sections.isEmpty, app.accounts.isEmpty {
                NoAccountView(app: app, icon: Icons.contacts, message: "Add an account to see your contacts.")
                    .frame(maxHeight: .infinity)
            } else if model.sections.isEmpty {
                empty.frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0).clearOfTabCapsule() }
    }

    /// No contact: a search that found none, or a way to the first one (or to a server that has them).
    private var empty: some View {
        ContentUnavailableView {
            ModuleLabel("No contacts", systemImage: Icons.contacts)
        } description: {
            if model.searchText.isEmpty, model.addState == .readOnly, let addBlocked {
                Text(ui: addBlocked)
            } else {
                Text(
                    ui: model.searchText.isEmpty
                        ? "Contacts from your servers show up here." : "No contact matches.")
            }
        } actions: {
            if model.searchText.isEmpty {
                switch model.addState {
                case .canAdd:
                    Button { app.contactEditor = ContactEditorRequest() } label: { Text(ui: "New contact") }
                        .buttonStyle(.borderedProminent)
                case .noBook:
                    Button { app.isAddingAccount = true } label: { Text(ui: "Add account") }
                        .buttonStyle(.borderedProminent)
                case .readOnly:
                    EmptyView()
                }
            }
        }
    }

    private var header: some View {
        TabHeader(app: app, title: L10n.string("Contacts"), titleID: "contacts.title") {
            Button {
                if !isSearching, !model.searchText.isEmpty {
                    // The field stays shown with its text: it takes the focus now, as it will not appear.
                    searchFocused = true
                } else {
                    focusesSearch = !isSearching
                }
                withAnimation(.snappy) { isSearching.toggle() }
            } label: {
                Image(systemName: Icons.search)
            }
            .accessibilityLabel(Text(ui: "Search contacts"))
            .accessibilityIdentifier("contacts.searchButton")
            Button { app.contactEditor = ContactEditorRequest() } label: {
                Image(systemName: Icons.add)
            }
            // No address book takes a new contact: the line under the header says why.
            .disabled(!model.canAdd)
            .accessibilityLabel(Text(ui: "New contact"))
            .accessibilityHint(addBlocked.map { Text(ui: $0) } ?? Text(verbatim: ""))
        } below: {
            if isSearching || !model.searchText.isEmpty {
                searchField
            }
            if let addBlocked, !app.accounts.isEmpty, !model.sections.isEmpty {
                Text(ui: addBlocked)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Why + is dimmed, when it is.
    private var addBlocked: LocalizedStringKey? {
        switch model.addState {
        case .canAdd: nil
        case .noBook: "No address book to add contacts to."
        case .readOnly: "Your address books are read-only."
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.sections, id: \.letter) { section in
                    Section {
                        ForEach(section.contacts) { contact in
                            row(contact)
                        }
                    } header: {
                        SectionHeader(verbatim: section.letter)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await app.pullContacts() }
            .overlay(alignment: .trailing) {
                AlphabetIndex(model: model) { letter in
                    // The section's first row: an id on a Section is not reliable inside a List.
                    if let first = model.sections.first(where: { $0.letter == letter })?.contacts.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
                .padding(.trailing, 2)
                .padding(.vertical, 8)
            }
        }
    }

    private func row(_ contact: Contact) -> some View {
        Button {
            if isWide {
                model.selected = contact.id
            } else {
                model.path = [contact.id]
            }
        } label: {
            HStack(spacing: 12) {
                ContactAvatar(contact: contact, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: contact.details.name.isEmpty ? L10n.string("(No name)") : contact.details.name)
                        .font(.title3)
                        .lineLimit(1)
                    let detail = contact.details.organization.isEmpty
                        ? (contact.details.emails.first?.value ?? "") : contact.details.organization
                    if !detail.isEmpty && detail != contact.details.name {
                        Text(verbatim: detail).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isWide && model.selected == contact.id ? Theme.selectedRow : nil)
        .accessibilityAddTraits(isWide && model.selected == contact.id ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: Icons.search).foregroundStyle(Theme.secondaryText)
            TextField(text: $model.searchText) {
                Text(ui: "Search contacts")
            }
            .focused($searchFocused)
            .onAppear {
                if focusesSearch { searchFocused = true }
                focusesSearch = false
            }
            .submitLabel(.search)
            .plainEntry()
            .accessibilityIdentifier("contacts.search")
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: Icons.clear).foregroundStyle(Theme.secondaryText)
                }
                .accessibilityLabel(Text(ui: "Clear"))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: fieldHeight)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A contact's picture when it has one, else the initials.
struct ContactAvatar: View {
    let contact: Contact
    var size: CGFloat = 40

    var body: some View {
        if let image = ContactPhotos.image(for: contact, pixels: Int(size * 3)) {
            Image(decorative: image, scale: 3)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            initials
        }
    }

    private var initials: some View {
        Avatar(
            name: contact.details.name, email: contact.details.emails.first?.value ?? contact.details.name,
            size: size)
    }
}
