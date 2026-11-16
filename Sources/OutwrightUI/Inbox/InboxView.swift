// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// The mail list: the header, conversations by day, swipes, pull to refresh, and the
/// floating Drafts / New mail capsule.
struct InboxView: View {
    @Bindable var app: AppModel
    @Bindable var model: InboxModel
    @Binding var path: [MessageID]
    /// Beside the open message on a wide screen: a tap selects the row instead of opening it.
    var selects = false
    @AppStorage(SettingsKeys.focusedInbox) private var focusedInbox = true

    var body: some View {
        VStack(spacing: 0) {
            InboxHeader(app: app, inbox: model)
            if model.failed {
                ProblemBanner(text: L10n.string("Mail couldn't be read from this phone's storage."))
            }
            if app.draftNotKept != nil {
                Button { app.draftNotKept = nil } label: {
                    ProblemBanner(text: L10n.string("A message you were writing could not be kept as a draft."))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(ui: "Tap to dismiss"))
            }
            ForEach(app.syncProblems) { problem in
                ProblemBanner(
                    text: "\(problem.account.displayName): \(problem.problem.reason)",
                    onTap: { app.showSettings(for: problem) }, tapHint: Text(ui: "Opens the account's settings"),
                    accessory: {
                        if problem.problem == .signInAgain {
                            SignInAgainButton(app: app, account: problem.account)
                        }
                    })
            }
            list
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            FloatingActions(app: app)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: model.observed) { await model.observe() }
        .task {
            // The watchers record their errors as they happen; look every half minute.
            while !Task.isCancelled {
                await app.updateSyncProblems()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: app.scope) { _, scope in model.scope = scope }
        .onChange(of: focusedInbox, initial: true) { _, isOn in model.isFocusedInboxOn = isOn }
    }

    private var showsAccountColors: Bool {
        if case .allAccounts = model.scope { return app.accounts.count > 1 }
        return false
    }

    private var list: some View {
        List {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                } header: {
                    if index > 0 || !Calendar.autoupdatingCurrent.isDateInToday(section.id) {
                        Text(section.title)
                            .font(.title3)
                            .foregroundStyle(Theme.secondaryText)
                            .textCase(nil)
                    }
                }
            }
            // The end of the list: while it is in sight, more is shown, and older mail fetched.
            HStack {
                Spacer()
                if model.isLoadingOlder {
                    ProgressView()
                }
                Spacer()
            }
            .frame(height: 44)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
            .accessibilityIdentifier("inbox.end")
            .task(id: model.limit) { await model.loadMore() }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 90, for: .scrollContent)
        .refreshable { await model.refresh() }
        .overlay {
            if model.sections.isEmpty, model.filter != .all {
                ContentUnavailableView {
                    Label { Text(ui: "No mail matches the filter") } icon: { Image(systemName: Icons.filter) }
                } actions: {
                    Button { model.filter = .all } label: { Text(ui: "Clear filter") }
                        .accessibilityIdentifier("inbox.clearFilter")
                }
            } else if model.sections.isEmpty {
                ContentUnavailableView {
                    Label { Text(ui: "No mail") } icon: { Image(systemName: Icons.folder(model.folderKind ?? .inbox)) }
                } description: {
                    Text(ui: "Nothing here right now.")
                }
            }
        }
    }

    private func rowView(_ row: MessageRow) -> some View {
        Button {
            if model.folderKind == .drafts {
                app.compose(.draft(row.id))
            } else if selects {
                model.selected = row.id
            } else {
                path.append(row.id)
            }
        } label: {
            MessageRowView(
                row: row, label: model.label(row),
                accountColor: showsAccountColors ? accountColor(row.accountID) : nil)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox.row")
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 16))
        .listRowBackground(selects && model.selected == row.id ? Theme.selectedRow : Theme.background)
        .accessibilityAddTraits(selects && model.selected == row.id ? .isSelected : [])
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation { model.swipeLeft(row.id) }
            } label: {
                ModuleLabel("Delete", systemImage: Icons.delete)
            }
            .tint(Theme.delete)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { model.swipeRight(row.id) }
            } label: {
                if row.isFlagged {
                    ModuleLabel("Unflag", systemImage: "flag.slash")
                } else {
                    ModuleLabel("Flag", systemImage: Icons.flag)
                }
            }
            .tint(Theme.flag)
        }
    }

    private func accountColor(_ id: AccountID) -> Color? {
        app.accounts.first { $0.id == id }.map { Theme.avatarColor($0.colorIndex) }
    }
}
