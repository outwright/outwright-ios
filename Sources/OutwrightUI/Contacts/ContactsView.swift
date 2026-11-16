// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The Contacts tab: title and plus, the list in letter sections with the alphabet on the right,
/// and at the bottom the search field and the filter button.
struct ContactsView: View {
    let app: AppModel
    @Bindable var model: ContactsModel
    @State private var isFiltering = false
    @Environment(\.horizontalSizeClass) private var widthClass

    /// Wide enough for the list and the card side by side.
    private var isWide: Bool { widthClass == .regular }

    var body: some View {
        Group {
            if isWide {
                GeometryReader { geometry in
                    let listWidth = MailPanes.listWidth(geometry.size.width)
                    HStack(spacing: 0) {
                        listColumn
                            .standsOnTabCapsule()
                            .frame(width: listWidth)
                        Rectangle().fill(Theme.separator).frame(width: 1).ignoresSafeArea()
                        card
                            .besideTabCapsule(from: listWidth + 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                listColumn
            }
        }
        .task { await model.observe() }
        .sheet(
            isPresented: $isFiltering, onDismiss: { app.openPending() },
            content: { ContactFilterSheet(model: model).presentationDetents([.medium, .large]) })
        .closesForEvents(isOpen: isFiltering) { isFiltering = false }
        // A turn between one column and two keeps the open card open.
        .onChange(of: isWide) { _, wide in carry(wide: wide) }
    }

    @ViewBuilder private var card: some View {
        if let id = model.selected, let contact = stored(id) {
            PersonCardView(app: app, request: PersonRequest(contact: id, account: contact.accountID), inPane: true)
                .id(id)
        } else {
            ContentUnavailableView {
                Label { Text(ui: "No contact selected") } icon: { Image(systemName: Icons.contacts) }
            }
            .background(Theme.drawerBackground)
        }
    }

    /// The card shown as a sheet in one column becomes the selection in two, and the other way round.
    /// A card opened from elsewhere (an address in a message) stays a sheet; on another tab the
    /// selection waits for the Contacts tab.
    private func carry(wide: Bool) {
        if wide {
            guard app.selectedTab == .contacts, let id = app.personToShow?.contact else { return }
            model.selected = id
            app.personToShow = nil
        } else {
            guard app.selectedTab == .contacts, app.personToShow == nil, let id = model.selected,
                let contact = stored(id) else { return }
            model.selected = nil
            app.personToShow = PersonRequest(contact: id, account: contact.accountID)
        }
    }

    /// The contact, from the list or else the store (a search may hide it from the list).
    private func stored(_ id: ContactID) -> Contact? {
        model.sections.lazy.flatMap(\.contacts).first { $0.id == id } ?? (try? app.store.contact(id)) ?? nil
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            topBar
            if model.failed {
                ProblemBanner(text: L10n.string("Contacts couldn't be read. Try again."))
            }
            if model.sections.isEmpty {
                ContentUnavailableView {
                    ModuleLabel("No contacts", systemImage: Icons.contacts)
                } description: {
                    Text(
                        ui: model.searchText.isEmpty
                            ? "Contacts from your servers show up here." : "No contact matches.")
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { bottomBar.clearOfTabCapsule() }
    }

    private var topBar: some View {
        HStack {
            Text(ui: "Contacts").font(.largeTitle.bold())
            Spacer(minLength: 0)
            Button { app.contactEditor = ContactEditorRequest() } label: {
                Image(systemName: Icons.add)
                    .font(.title2.weight(.medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.primary)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text(ui: "New contact"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                        Text(verbatim: section.letter).font(.headline).foregroundStyle(Theme.accent)
                    }
                }
            }
            .listStyle(.plain)
            .overlay(alignment: .trailing) {
                AlphabetIndex(
                    letters: model.letters, available: Set(model.sections.map(\.letter))
                ) { letter in
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
                app.personToShow = PersonRequest(contact: contact.id, account: contact.accountID)
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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: Icons.search).foregroundStyle(Theme.secondaryText)
                TextField(text: $model.searchText) {
                    Text(ui: "Search contacts")
                }
                .submitLabel(.search)
                .plainEntry()
                .accessibilityIdentifier("contacts.search")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityLabel(Text(ui: "Clear"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
            Button { isFiltering = true } label: {
                Image(systemName: Icons.filter)
                    .font(.title3.weight(.medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(model.shownBooks == nil ? Color.primary : Theme.accent)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(Text(ui: "Address books"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
