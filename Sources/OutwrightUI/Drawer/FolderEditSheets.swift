// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// A folder sheet the drawer shows: a name to give, or a place to move to.
enum FolderSheet: Identifiable {
    /// A new folder under `parent` (nil: at the top) of `account`.
    case create(parent: Folder?, account: AccountID)
    case rename(Folder)
    case move(Folder)

    var id: String {
        switch self {
        case let .create(parent, account): "create-\(parent?.id.raw ?? 0)-\(account.raw)"
        case let .rename(folder): "rename-\(folder.id.raw)"
        case let .move(folder): "move-\(folder.id.raw)"
        }
    }
}

/// Asks for a folder's name; `save` gives the problem to show, or nil when it went through.
struct FolderNameSheet: View {
    let title: String
    let initial: String
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text(ui: "Folder name") }
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { Task { await commit() } }
                        .accessibilityIdentifier("folderEdit.name")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text(title))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await commit() }
                    } label: {
                        Text(ui: "Save")
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("folderEdit.save")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            name = initial
            focused = true
        }
    }

    private func commit() async {
        guard !isSaving else { return }
        isSaving = true
        problem = await save(name)
        isSaving = false
        if problem == nil {
            dismiss()
        }
    }
}

/// Where to move a folder: the top of the account, or under one of its folders.
struct FolderMoveSheet: View {
    let destinations: [FolderNode]
    let choose: (Folder?) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                Button {
                    Task { await pick(nil) }
                } label: {
                    Label(L10n.string("Top level"), systemImage: Icons.folder(.other))
                }
                .accessibilityIdentifier("folderMove.top")
                ForEach(destinations) { node in
                    Button {
                        Task { await pick(node.folder) }
                    } label: {
                        Label(FolderNames.name(node.folder), systemImage: Icons.folder(node.folder.kind))
                            .padding(.leading, CGFloat(node.indent + 1) * 20)
                    }
                    .accessibilityIdentifier("folderMove.row")
                }
            }
            .navigationTitle(Text(ui: "Move folder to"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(ui: "Cancel") }
                }
            }
        }
    }

    private func pick(_ folder: Folder?) async {
        problem = await choose(folder)
        if problem == nil {
            dismiss()
        }
    }
}

extension DeleteWarning {
    /// The confirmation's message for deleting `name`.
    func message(_ name: String) -> String {
        let question = String(format: L10n.string("Delete “%@” and everything in it?"), name)
        let loss = switch self {
        case let .count(count):
            String.localizedStringWithFormat(L10n.string("%lld messages will be deleted for good."), Int64(count))
        case .unknown:
            L10n.string("All its messages will be deleted for good.")
        }
        return question + " " + loss
    }
}
