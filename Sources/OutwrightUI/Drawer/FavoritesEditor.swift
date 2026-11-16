// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Choose which folders are Favorites.
struct FavoritesEditor: View {
    let model: DrawerModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<FolderID> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.editableFolders) { section in
                    Section {
                        ForEach(section.folders) { folder in
                            Button {
                                if chosen.contains(folder.id) {
                                    chosen.remove(folder.id)
                                } else {
                                    chosen.insert(folder.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: Icons.folder(folder.kind)).frame(width: 28)
                                    Text(FolderNames.name(folder))
                                    Spacer()
                                    if chosen.contains(folder.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(accountName(section))
                    }
                }
            }
            .navigationTitle(Text(ui: "Favorites"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.setFavorites(chosen)
                        dismiss()
                    } label: {
                        Text(ui: "Done")
                    }
                }
            }
        }
        .onAppear {
            chosen = Set(model.sections.first { $0.kind == .favorites }?.folders.map(\.id) ?? [])
        }
    }

    private func accountName(_ section: DrawerSection) -> String {
        guard case .account(let id) = section.kind else { return "" }
        return model.accounts.first { $0.id == id }?.email ?? ""
    }
}
