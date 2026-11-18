// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import Observation
public import OutwrightMIME
public import OutwrightModel
public import OutwrightStore

/// What a message shows once its body is here.
public struct MessageContent: Sendable {
    public var to: [Address]
    public var cc: [Address]
    public var text: String?
    public var html: String?
    public var attachments: [Attachment]
    /// The bytes of the message's calendar part (an invitation's), which the meeting card stands for.
    var calendar: Data?
    /// What opening the message found about its protection; nil: nothing.
    var facts: ProtectionFacts?
    /// The plain text was longer than `textLimit` and is shown cut short.
    public var isShortened = false
    /// It was opened from its protection, but what was inside could not be read as a message.
    public var isUnreadable: Bool { facts?.decryption == .unreadable }

    /// The most plain text shown, in characters.
    public static let textLimit = 200_000

    init(_ message: MIMEMessage) {
        to = message.to
        cc = message.cc
        html = message.htmlBody
        attachments = message.attachments
        calendar = message.calendar?.data
        if let full = message.textBody, full.count > Self.textLimit {
            text = String(full.prefix(Self.textLimit))
            isShortened = true
        } else {
            text = message.textBody
            isShortened = message.isTextShortened
        }
    }

    /// Reads a stored message away from the main actor.
    static func read(_ data: Data, store: MailStore, account: AccountID? = nil) async -> MessageContent? {
        await Task.detached(priority: .userInitiated) {
            // The text is cut while it is read, not after: four bytes at most for a character.
            let limits = MIMELimits(textBytes: textLimit * 4)
            return store.open(data, limits: limits, account: account).map {
                var content = MessageContent($0.message)
                content.facts = $0.facts
                return content
            }
        }.value
    }

    /// The attachments listed under the message: what isn't a picture shown inside it.
    /// A picture the HTML shows by `cid:` is not listed, however it was marked.
    public var files: [Attachment] { files(besideCard: false) }

    /// The attachments listed, without the calendar part when the meeting card shows it.
    public func files(besideCard: Bool) -> [Attachment] {
        let shown = html.map(Self.contentIDsUsed) ?? []
        return attachments.filter { attachment in
            if besideCard, let calendar, attachment.mimeType.lowercased() == "text/calendar",
                attachment.data == calendar {
                return false
            }
            guard attachment.mimeType.lowercased().hasPrefix("image/"), let cid = attachment.contentID else {
                return true
            }
            return !shown.contains(CIDSchemeHandler.normalize(cid))
        }
    }

    static func contentIDsUsed(_ html: String) -> Set<String> {
        var found = Set<String>()
        var rest = html[...]
        var count = 0
        while count < 1_000, let range = rest.range(of: "cid:", options: .caseInsensitive) {
            count += 1
            let tail = rest[range.upperBound...]
            let end = tail.firstIndex { "\"' >)".contains($0) } ?? tail.endIndex
            found.insert(CIDSchemeHandler.normalize(String(tail[..<end])))
            rest = tail[end...]
        }
        return found
    }
}

/// Who a message went to, as its header line says it.
public enum RecipientLine: Equatable, Sendable {
    /// The account's own address is among the recipients.
    case you
    /// Names (or addresses) of the recipients, the owner not among them.
    case others([String])
}

/// One message of the conversation on screen.
public struct ThreadItem: Identifiable, Sendable {
    public var row: MessageRow
    public var isExpanded: Bool
    public var content: MessageContent?
    public var isLoading = false
    /// The body could not be fetched or read.
    public var failed = false
    /// The owner chose Download pictures for this message.
    public var allowsRemote = false
    public var id: MessageID { row.id }
}

/// What the reading view does after an action.
public enum ReadingStep: Equatable, Sendable {
    /// Back to the list (on a phone; beside the list the conversation stays, its row selected).
    case close
    /// The conversation stays open.
    case stay
}

/// A conversation as the reading view shows it: oldest first, the latest open; opening it marks
/// it read; actions apply to the messages of the folder it was opened from.
@Observable @MainActor
public final class ThreadModel {
    @ObservationIgnored let store: MailStore
    @ObservationIgnored let fetchBody: @MainActor (MessageID) async -> Void
    public private(set) var opened: MessageID
    public private(set) var items: [ThreadItem] = []
    public private(set) var subject = ""
    /// Everything in view was deleted or moved away: the view closes.
    public private(set) var isGone = false
    public private(set) var failed = false
    /// Opened from Junk: its links and pictures stay shut, and Not junk is offered.
    public private(set) var isInJunk = false
    /// Opened from Trash: Delete is for good, and asks first.
    public private(set) var deleteNeedsConfirmation = false
    /// The address of the account the conversation is in.
    @ObservationIgnored private var ownerAddress = ""

    /// Reads a body into what is shown, off the main actor.
    @ObservationIgnored let read: @Sendable (Data) async -> MessageContent?
    /// The move or delete waiting out its undo window: its messages are left out; nil leaves out none.
    @ObservationIgnored public let pending: PendingMail?

    public convenience init(
        store: MailStore, message: MessageID, pending: PendingMail? = nil,
        fetchBody: @escaping @MainActor (MessageID) async -> Void
    ) {
        let account = (try? store.message(message))??.accountID
        self.init(store: store, message: message, pending: pending, fetchBody: fetchBody) { [store] in
            await MessageContent.read($0, store: store, account: account)
        }
    }

    init(
        store: MailStore, message: MessageID, pending: PendingMail? = nil,
        fetchBody: @escaping @MainActor (MessageID) async -> Void,
        read: @escaping @Sendable (Data) async -> MessageContent?
    ) {
        self.store = store
        self.opened = message
        self.fetchBody = fetchBody
        self.read = read
        self.pending = pending
        pending?.watch(self)
    }

    /// The newest message of the conversation, which the action bar acts on.
    public var latest: MessageRow? { items.last?.row }

    public func open() async {
        guard let first = loadRows() else { return }
        subject = first.subject
        for index in items.indices where !items[index].row.isRead {
            apply(.setRead(items[index].id, true))
            items[index].row.isRead = true
        }
        if let last = items.indices.last {
            items[last].isExpanded = true
            await load(at: last)
        }
    }

    /// A newer message of the same conversation became its row in the list (a reply came in): it joins
    /// the view, and what the owner opened, expanded or allowed stays as it was.
    public func follow(_ message: MessageID) async {
        guard message != opened else { return }
        opened = message
        await open()
    }

    /// The messages of the thread, from the folders that belong with the one it was opened in.
    private func loadRows() -> MessageRow? {
        do {
            let hidden = pending?.hidden ?? []
            guard let row = try store.message(opened), !hidden.contains(row.id) else {
                isGone = true
                items = []
                return nil
            }
            ownerAddress = try store.accounts().first { $0.id == row.accountID }?.email.lowercased() ?? ""
            let kinds = Dictionary(
                try store.folders(row.accountID).map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
            let apart: Set<FolderKind> = [.trash, .junk]
            let openedKind = kinds[row.folderID] ?? .other
            isInJunk = openedKind == .junk
            deleteNeedsConfirmation = openedKind == .trash
            let rows = try store.thread(row.threadID, account: row.accountID).filter { other in
                guard !hidden.contains(other.id) else { return false }
                let otherKind = kinds[other.folderID] ?? .other
                return other.id == row.id || apart.contains(openedKind) || !apart.contains(otherKind)
            }
            let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            items = rows.map { row in
                var item = previous[row.id] ?? ThreadItem(row: row, isExpanded: false)
                item.row = row
                return item
            }
            return row
        } catch {
            failed = true
            return nil
        }
    }

    public func toggle(_ id: MessageID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isExpanded.toggle()
        if items[index].isExpanded { await load(at: index) }
    }

    /// Reads the message's body again (a key it was signed with came in): what it says now is shown
    /// without the owner opening it again.
    public func reverify(_ id: MessageID) async {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isLoading,
              let data = (try? store.body(id)) ?? nil else { return }
        guard let content = await read(data), let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].content = content
        items[index].failed = false
    }

    public func recipients(of item: ThreadItem) -> RecipientLine {
        let all = (item.content?.to ?? item.row.to) + (item.content?.cc ?? item.row.cc)
        if !ownerAddress.isEmpty, all.contains(where: { $0.email.lowercased() == ownerAddress }) {
            return .you
        }
        return .others(all.prefix(20).map { $0.name.flatMap { $0.isEmpty ? nil : $0 } ?? $0.email })
    }

    /// Downloads the message's pictures, unless its content may not fetch any.
    public func allowPictures(_ id: MessageID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].content?.facts?.allowsRemoteContent ?? true
        else { return }
        items[index].allowsRemote = true
    }

    /// Fetches the body when it isn't here, then reads it.
    private func load(at index: Int) async {
        // Not again while it is being read (closed and opened meanwhile).
        guard items.indices.contains(index), items[index].content == nil, !items[index].isLoading else { return }
        let id = items[index].id
        items[index].isLoading = true
        var data = (try? store.body(id)) ?? nil
        if data == nil {
            await fetchBody(id)
            data = (try? store.body(id)) ?? nil
        }
        let content: MessageContent? = if let data { await read(data) } else { nil }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Storing the body may have rewritten the row (an encrypted mail's subject, decrypted).
        if let row = try? store.message(id) {
            items[index].row = row
            if id == opened { subject = row.subject }
        }
        // Loading until the text is read, so it never shows blank in between.
        items[index].isLoading = false
        guard let content else {
            items[index].failed = true
            return
        }
        items[index].content = content
        items[index].failed = false
    }

    // MARK: Actions

    /// The messages acted on: those of the conversation in the folder it was opened from.
    private var inFolder: [MessageRow] {
        guard let row = items.first(where: { $0.id == opened })?.row else { return [] }
        return (try? Conversation.inFolder(of: row, store: store)) ?? [row]
    }

    /// Marks the newest message unread, at once: the view goes back to the list after it.
    @discardableResult
    public func markUnread() -> ReadingStep {
        guard let target = inFolder.last else { return .stay }
        commitIfStaged([target.id])
        apply(.setRead(target.id, false))
        refreshRows()
        return failed ? .stay : .close
    }

    public func toggleFlag() {
        guard let target = inFolder.last else { return }
        commitIfStaged([target.id])
        apply(.setFlagged(target.id, !target.isFlagged))
        refreshRows()
    }

    public func delete() { stage(UndoText.deleted) { .delete($0) } }
    public func archive() { stage(UndoText.archived) { .move($0, to: .archive) } }
    public func junk() { stage(UndoText.movedToJunk) { .move($0, to: .junk) } }
    /// Not junk: the conversation of Junk goes to the Inbox.
    public func notJunk() {
        stage({ UndoText.moved($0, to: L10n.string("Inbox")) }, { .move($0, to: .inbox) })
    }

    public func move(to folder: FolderID) {
        let name = store.findFolder(folder).map(FolderNames.name) ?? ""
        stage({ UndoText.moved($0, to: name) }, { .moveTo($0, folder) })
    }

    /// Deletes the conversation for good (from Trash), at once: the owner was asked.
    public func deleteForGood() {
        let messages = inFolder
        commitIfStaged(messages.map(\.id))
        moveAll(messages) { .delete($0) }
    }

    /// A move or delete of the conversation waits out the undo window and leaves the view at once;
    /// without the undo window (nothing to stage with) it is made at once.
    private func stage(_ text: (Int) -> String, _ action: (MessageID) -> MailAction) {
        let messages = inFolder
        guard let pending, !messages.isEmpty else {
            moveAll(messages, action)
            return
        }
        failed = false
        pending.stage(messages.map { action($0.id) }, hiding: Set(messages.map(\.id)), text: text(1))
    }

    private func moveAll(_ messages: [MessageRow], _ action: (MessageID) -> MailAction) {
        do {
            try Conversation.apply(messages, store: store, action)
            failed = false
            isGone = true
        } catch {
            failed = true
            refreshRows()
        }
    }

    /// Commits the staged batch when it holds any of these messages, so changes reach the store in order.
    private func commitIfStaged(_ messages: [MessageID]) {
        guard let pending, !pending.hidden.isDisjoint(with: messages) else { return }
        pending.commitNow()
    }

    /// Sorts the sender (of the newest message the owner did not send) into Focused or Other from
    /// now on, with the mail already here.
    public func setInboxClass(_ inboxClass: InboxClass) {
        let received = items.last { $0.row.from.email.lowercased() != ownerAddress }
        guard let sender = received?.row.from.email, !sender.isEmpty else { return }
        do {
            try store.setOverride(sender, inboxClass)
            failed = false
        } catch {
            failed = true
        }
        refreshRows()
    }

    /// The folders the conversation can be moved to, as the drawer's tree.
    public func folders() -> [FolderNode] {
        guard let account = latest?.accountID, let all = try? store.folders(account) else { return [] }
        let current = inFolder.first?.folderID
        return DrawerModel.tree(all).filter { $0.folder.id != current }
    }

    private func refreshRows() {
        _ = loadRows()
    }

    /// `failed` tells of the last change: one that goes through clears it.
    private func apply(_ action: MailAction) {
        do {
            try store.apply(action)
            failed = false
        } catch {
            failed = true
        }
    }
}

extension ThreadModel: PendingMailWatcher {
    func pendingMailChanged() {
        refreshRows()
    }
}
