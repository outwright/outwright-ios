// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
import OutwrightStore

/// What the list does to its conversations: moves and deletes through the undo window, changes made
/// at once, selection mode and Mark all read.
extension InboxModel {
    // MARK: Acting on conversations

    /// The rows of the list with these ids.
    func rows(_ ids: Set<MessageID>) -> [MessageRow] {
        sections.flatMap(\.rows).filter { ids.contains($0.id) }
    }

    func row(_ id: MessageID) -> MessageRow? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }
    }

    /// The messages of the row's conversation in its folder.
    func conversation(_ row: MessageRow) -> [MessageRow] {
        (try? Conversation.inFolder(of: row, store: store)) ?? [row]
    }

    /// Stages an action on every message of the rows' conversations, leaving them out of the list.
    private func stageMove(_ ids: Set<MessageID>, text: (Int) -> String, action: (MessageID) -> MailAction) {
        let chosen = rows(ids)
        guard !chosen.isEmpty else { return }
        let messages = chosen.flatMap(conversation)
        selection = []
        pending.stage(messages.map { action($0.id) }, hiding: Set(messages.map(\.id)), text: text(chosen.count))
    }

    public func delete(_ ids: Set<MessageID>) {
        stageMove(ids, text: UndoText.deleted, action: { .delete($0) })
    }

    public func archive(_ ids: Set<MessageID>) {
        stageMove(ids, text: UndoText.archived, action: { .move($0, to: .archive) })
    }

    public func move(_ ids: Set<MessageID>, to folder: FolderID) {
        let name = (store.findFolder(folder)).map(FolderNames.name) ?? ""
        stageMove(ids, text: { UndoText.moved($0, to: name) }, action: { .moveTo($0, folder) })
    }

    /// Deletes the conversations for good (from Trash), at once: the owner was asked.
    public func deleteForGood(_ ids: Set<MessageID>) {
        let messages = rows(ids).flatMap(conversation)
        selection = []
        now(messages.map { .delete($0.id) })
    }

    /// The folders the rows can be moved to: those of their account, when they are all of one.
    public func moveTargets(_ ids: Set<MessageID>) -> [FolderNode] {
        let chosen = rows(ids)
        let accounts = Set(chosen.map(\.accountID))
        guard accounts.count == 1, let account = accounts.first, let all = try? store.folders(account) else {
            return []
        }
        let current = Set(chosen.map(\.folderID))
        return DrawerModel.tree(all).filter { current.count != 1 || !current.contains($0.folder.id) }
    }

    /// Changes made at once, without undo (only moves and deletes wait out the window). A staged batch
    /// that holds any of the same messages is committed first, so the changes reach the store in order.
    func now(_ actions: [MailAction]) {
        commitIfStaged(actions.map(\.target))
        var broke = false
        do {
            try Conversation.apply(actions, store: store)
        } catch {
            broke = true
        }
        reload()
        if broke { failed = true }
    }

    // MARK: Selection

    public var isSelecting: Bool { !selection.isEmpty }

    /// A long press: selection mode starts with the row, or the row joins it.
    public func beginSelecting(_ id: MessageID) {
        selection.insert(id)
    }

    public func toggleSelection(_ id: MessageID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public var allSelected: Bool {
        let all = sections.flatMap(\.rows)
        return !all.isEmpty && all.allSatisfy { selection.contains($0.id) }
    }

    public func selectAll() {
        selection = Set(sections.flatMap(\.rows).map(\.id))
    }

    public func endSelecting() {
        selection = []
    }

    public func archiveSelected() { archive(selection) }
    public func deleteSelected() { delete(selection) }
    public func deleteSelectedForGood() { deleteForGood(selection) }
    public func moveSelected(to folder: FolderID) { move(selection, to: folder) }

    /// Every selected row is flagged (Flag then unflags them).
    public var selectionIsFlagged: Bool { rows(selection).allSatisfy(\.isFlagged) }
    /// Every selected row is read (Read then marks them unread).
    public var selectionIsRead: Bool { rows(selection).allSatisfy(\.isRead) }

    /// Flags the selected rows, or unflags them when all are flagged; at once.
    public func flagSelected() {
        let chosen = rows(selection)
        guard !chosen.isEmpty else { return }
        let value = !selectionIsFlagged
        selection = []
        now(chosen.map { .setFlagged($0.id, value) })
    }

    /// Marks the selected conversations read, or unread when all are read; at once.
    public func readSelected() {
        let chosen = rows(selection)
        guard !chosen.isEmpty else { return }
        let value = !selectionIsRead
        selection = []
        now(chosen.flatMap(conversation).map { .setRead($0.id, value) })
    }

    /// Every unread message of the folder in view (every Inbox for all accounts) is marked read, not
    /// only the rows loaded.
    public func markAllRead() {
        var broke = false
        do {
            let unread = try store.unreadMessages(scope)
            commitIfStaged(unread)
            try store.apply(unread.map { .setRead($0, true) })
        } catch {
            broke = true
        }
        reload()
        if broke { failed = true }
    }

    /// Commits the staged batch when it holds any of these messages.
    private func commitIfStaged(_ messages: [MessageID]) {
        guard !pending.hidden.isDisjoint(with: messages) else { return }
        pending.commitNow()
    }
}
