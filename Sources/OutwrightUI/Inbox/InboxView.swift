// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// The mail list: the header, conversations by day, swipes, pull to refresh, and the
/// floating Drafts / New mail capsule; a long press starts selection mode, with its own bar.
struct InboxView: View {
    @ScaledMetric(relativeTo: .body) private var loadingRow: CGFloat = 44
    @Bindable var app: AppModel
    @Bindable var model: InboxModel
    @Binding var path: [MessageID]
    /// Beside the open message on a wide screen: a tap selects the row instead of opening it.
    var selects = false
    @AppStorage(SettingsKeys.focusedInbox) private var focusedInbox = true
    // Read so a change in Settings redraws the rows' swipes.
    @AppStorage(SettingsKeys.swipeLeading) private var swipeRight = SwipeAction.leadingDefault.rawValue
    @AppStorage(SettingsKeys.swipeTrailing) private var swipeLeft = SwipeAction.trailingDefault.rawValue
    @Environment(\.undoToastRoom) private var toastRoom
    /// The conversations to move, while the folder picker is open.
    @State private var moving: Chosen?
    /// The conversations to delete for good, while the question is asked.
    @State private var deletingForGood: Chosen?

    var body: some View {
        VStack(spacing: 0) {
            InboxHeader(app: app, inbox: model)
            if model.failed || app.pendingMail.failed {
                ProblemBanner(text: L10n.string("Mail couldn't be read from this phone's storage."))
            }
            if app.draftNotKept != nil {
                Button { app.draftNotKept = nil } label: {
                    ProblemBanner(text: L10n.string("A message you were writing could not be kept as a draft."))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(ui: "Tap to dismiss"))
            }
            AttentionBanners(app: app)
            list
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            Group {
                if model.isSelecting {
                    SelectionBar(
                        model: model, delete: { delete(model.selection) }, move: { moving = Chosen(model.selection) })
                } else {
                    FloatingActions(app: app)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12 + toastRoom)
            .animation(.snappy, value: toastRoom)
            .animation(.snappy, value: model.isSelecting)
        }
        .sheet(item: $moving, onDismiss: { app.openPending() }, content: { chosen in
            let targets = model.moveTargets(chosen.ids)
            MovePicker(folders: targets, newFolder: app.newFolder(in: targets)) { folder in
                withAnimation { model.move(chosen.ids, to: folder) }
            }
        })
        .closesForEvents(isOpen: moving != nil) { moving = nil }
        .confirmationDialog(
            Text(ui: "Delete for good?"), isPresented: Binding(
                get: { deletingForGood != nil }, set: { if !$0 { deletingForGood = nil } }),
            titleVisibility: .visible, presenting: deletingForGood
        ) { chosen in
            Button(role: .destructive) {
                withAnimation { model.deleteForGood(chosen.ids) }
            } label: {
                Text(ui: "Delete for good")
            }
            .accessibilityIdentifier("inbox.deleteForGood")
        } message: { _ in
            Text(ui: "It can't be brought back.")
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: model.observed) { await model.observe() }
        .onChange(of: app.scope) { _, scope in model.scope = scope }
        .onChange(of: focusedInbox, initial: true) { _, isOn in model.isFocusedInboxOn = isOn }
    }

    /// Delete: through the undo window, or for good once asked where it is for good.
    private func delete(_ ids: Set<MessageID>) {
        if model.needsConfirmation(for: .delete) {
            deletingForGood = Chosen(ids)
        } else {
            withAnimation { model.delete(ids) }
        }
    }

    /// The list is empty because the mail is still on its way: the account in view, or any of them
    /// when all are shown, has not looked at its Inbox yet.
    private var waitsForFirstSync: Bool {
        if let account = app.accountInView { return app.isFirstSync(account.id) }
        if case .folder = model.scope { return false }
        return app.accounts.contains { app.isFirstSync($0.id) }
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
                        SectionHeader(verbatim: section.title)
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
            .frame(minHeight: loadingRow)
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
            } else if model.sections.isEmpty, app.accounts.isEmpty {
                NoAccountView(app: app, icon: Icons.mail, message: "Add an account to read your mail.")
            } else if model.sections.isEmpty, waitsForFirstSync {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(ui: "Getting your mail…")
                        .font(.headline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox.gettingMail")
                // Until the coordinator has looked: asked again every few seconds while this shows.
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        await app.updateFirstSync()
                    }
                }
            } else if model.sections.isEmpty, model.showsFocusedOther, model.inboxClass == .focused {
                ContentUnavailableView {
                    Label { Text(ui: "Nothing in Focused") } icon: { Image(systemName: Icons.focused) }
                } description: {
                    Text(ui: "Newsletters and the like are in Other.")
                } actions: {
                    Button { model.inboxClass = .other } label: { Text(ui: "See Other") }
                        .accessibilityIdentifier("inbox.seeOther")
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
        let isChosen = model.selection.contains(row.id)
        let isOpenBeside = selects && model.selected == row.id
        return MessageRowView(
            row: row, label: model.label(row),
            accountColor: showsAccountColors ? accountColor(row.accountID) : nil,
            isSelected: model.isSelecting ? isChosen : nil)
            .contentShape(Rectangle())
            .onTapGesture { tap(row) }
            .onLongPressGesture(minimumDuration: 0.4) { withAnimation(.snappy) { model.beginSelecting(row.id) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap(row) }
            .accessibilityAction(named: Text(ui: "Select")) { model.beginSelecting(row.id) }
            .accessibilityIdentifier("inbox.row")
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 16))
            .listRowBackground(isChosen || (isOpenBeside && !model.isSelecting) ? Theme.selectedRow : Theme.background)
            .accessibilityAddTraits(isOpenBeside ? .isSelected : [])
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !model.isSelecting { swipeButton(.trailing, row) }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !model.isSelecting { swipeButton(.leading, row) }
            }
    }

    private func tap(_ row: MessageRow) {
        if model.isSelecting {
            withAnimation(.snappy) { model.toggleSelection(row.id) }
        } else if model.folderKind == .drafts {
            app.compose(.draft(row.id))
        } else if selects {
            model.selected = row.id
        } else {
            path.append(row.id)
        }
    }

    /// The button a swipe from `edge` shows, as Settings chose it; none for None.
    @ViewBuilder private func swipeButton(_ edge: SwipeEdge, _ row: MessageRow) -> some View {
        let action = model.swipeAction(edge)
        switch action {
        case .none:
            EmptyView()
        case .delete:
            if model.needsConfirmation(for: .delete) {
                Button { delete([row.id]) } label: { ModuleLabel("Delete", systemImage: Icons.delete) }
                    .tint(Theme.delete)
            } else {
                Button(role: .destructive) { delete([row.id]) } label: {
                    ModuleLabel("Delete", systemImage: Icons.delete)
                }
                .tint(Theme.delete)
            }
        case .move:
            Button { moving = Chosen([row.id]) } label: { ModuleLabel("Move", systemImage: Icons.move) }
                .tint(Theme.move)
        case .archive, .flag, .read:
            Button {
                withAnimation { model.swipe(edge, on: row.id) }
            } label: {
                swipeLabel(action, row)
            }
            .tint(action == .archive ? Theme.archive : action == .flag ? Theme.flag : Theme.read)
        }
    }

    @ViewBuilder private func swipeLabel(_ action: SwipeAction, _ row: MessageRow) -> some View {
        switch action {
        case .archive: ModuleLabel("Archive", systemImage: Icons.archive)
        case .flag where row.isFlagged: ModuleLabel("Unflag", systemImage: Icons.unflag)
        case .flag: ModuleLabel("Flag", systemImage: Icons.flag)
        case .read where row.isRead: ModuleLabel("Mark as unread", systemImage: Icons.unread)
        case .read: ModuleLabel("Mark as read", systemImage: Icons.markRead)
        case .delete, .move, .none: EmptyView()
        }
    }

    private func accountColor(_ id: AccountID) -> Color? {
        app.accounts.first { $0.id == id }.map { Theme.avatarColor($0.colorIndex) }
    }
}

/// Conversations an action waits on (the folder picker, a question), by their rows.
struct Chosen: Identifiable {
    let id = UUID()
    let ids: Set<MessageID>

    init(_ ids: Set<MessageID>) {
        self.ids = ids
    }
}
