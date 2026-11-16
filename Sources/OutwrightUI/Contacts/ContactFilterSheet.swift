// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Which address books the list shows: all, or the ones ticked, grouped under their account.
struct ContactFilterSheet: View {
    @Bindable var model: ContactsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { model.shownBooks = nil } label: {
                    check(Text(ui: "All address books"), isChosen: model.shownBooks == nil)
                }
                ForEach(model.bookGroups, id: \.account.id) { group in
                    Section(group.account.displayName) {
                        ForEach(group.books) { book in
                            Button { toggle(book) } label: {
                                check(Text(verbatim: book.name), isChosen: model.shownBooks?.contains(book.id) ?? true)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .navigationTitle(Text(ui: "Address books"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(ui: "Done") }
                }
            }
        }
    }

    private func check(_ title: Text, isChosen: Bool) -> some View {
        HStack {
            title
            Spacer()
            if isChosen { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
        .contentShape(Rectangle())
    }

    /// Ticking the last unticked book is the same as all; unticking every book shows all again.
    private func toggle(_ book: AddressBook) {
        let every = Set(model.bookGroups.flatMap(\.books).map(\.id))
        var shown = model.shownBooks ?? every
        if shown.contains(book.id) { shown.remove(book.id) } else { shown.insert(book.id) }
        model.shownBooks = (shown.isEmpty || shown == every) ? nil : shown
    }
}
