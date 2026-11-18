// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The drawer's right column on the Contacts tab: which address books the list shows, all or the ones
/// ticked, grouped under their account. With one account chosen in the rail, only its books are listed.
struct DrawerAddressBooks: View {
    @Bindable var model: ContactsModel
    /// The account chosen in the rail; nil is all accounts.
    let account: AccountID?

    private var groups: [(account: Account, books: [AddressBook])] {
        model.bookGroups.filter { account == nil || $0.account.id == account }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.shownBooks = nil } label: {
                row(Text(ui: "All address books"), isChosen: model.shownBooks == nil)
            }
            .buttonStyle(.plain)
            ForEach(groups, id: \.account.id) { group in
                SectionHeader(verbatim: group.account.displayName)
                    .padding(.top, 14).padding(.bottom, 4)
                ForEach(group.books) { book in
                    Button { toggle(book) } label: {
                        row(Text(verbatim: book.name), isChosen: model.shownBooks?.contains(book.id) ?? true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ title: Text, isChosen: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: isChosen ? Icons.checkboxOn : Icons.checkboxOff)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Theme.accent)
            title.font(.title3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Ticking the last unticked book is the same as all; unticking every book shows all again.
    private func toggle(_ book: AddressBook) {
        let every = Set(model.bookGroups.flatMap(\.books).map(\.id))
        var shown = model.shownBooks ?? every
        if shown.contains(book.id) { shown.remove(book.id) } else { shown.insert(book.id) }
        model.shownBooks = (shown.isEmpty || shown == every) ? nil : shown
    }
}
