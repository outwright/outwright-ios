// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
public import OutwrightStore

/// The mail list of a folder, or of every account's Inbox: Focused or Other, a filter, by day.
@Observable @MainActor
public final class InboxModel {
    @ObservationIgnored let store: MailStore
    @ObservationIgnored let refresher: @MainActor () async -> Void
    /// Brings older mail of a list from the servers; false when none is left.
    @ObservationIgnored let olderFetcher: @MainActor (InboxScope) async -> Bool
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let calendar: Calendar

    public var scope: InboxScope {
        didSet {
            guard scope != oldValue else { return }
            selected = nil
            startOver()
        }
    }
    /// The message beside the list on a wide screen. When it leaves the list, the next one takes its place.
    public var selected: MessageID?

    /// Whether the message is a row of the list.
    public func shows(_ message: MessageID) -> Bool {
        sections.contains { $0.rows.contains { $0.id == message } }
    }
    /// Settings › Focused Inbox: when off, an Inbox shows both classes and no Focused/Other control.
    public var isFocusedInboxOn: Bool {
        didSet { if isFocusedInboxOn != oldValue { reload() } }
    }
    public var inboxClass: InboxClass = .focused {
        didSet { if inboxClass != oldValue { listChosen() } }
    }
    public var filter: InboxFilter = .all {
        didSet { if filter != oldValue { listChosen() } }
    }
    /// The owner chose another list (a filter, Focused or Other): the open message goes when it is not in it.
    @ObservationIgnored private var dropsHidden = false
    /// Rows shown at most: a page more each time the end of the list is reached.
    public private(set) var limit = InboxModel.page
    public static let page = 200
    /// Older mail is being fetched from the servers for the end of the list.
    public private(set) var isLoadingOlder = false
    @ObservationIgnored private var serverMayHaveMore = true
    @ObservationIgnored private var shownCount = 0
    public private(set) var sections: [DaySection] = []
    /// The kind of folder in view; nil for every account's Inbox.
    public private(set) var folderKind: FolderKind?
    /// The store failed the last time it was asked.
    public private(set) var failed = false
    public private(set) var isRefreshing = false

    public init(
        store: MailStore, scope: InboxScope, calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init, refresher: @escaping @MainActor () async -> Void = {},
        olderFetcher: @escaping @MainActor (InboxScope) async -> Bool = { _ in false },
        defaults: UserDefaults = .standard
    ) {
        self.olderFetcher = olderFetcher
        self.store = store
        isFocusedInboxOn = defaults.object(forKey: SettingsKeys.focusedInbox) as? Bool ?? true
        self.scope = scope
        self.calendar = calendar
        self.now = now
        self.refresher = refresher
        reload()
    }

    /// Focused and Other sort an Inbox only, and only while the setting is on.
    public var showsFocusedOther: Bool {
        isFocusedInboxOn && (folderKind == nil || folderKind == .inbox)
    }

    public var query: InboxQuery {
        InboxQuery(scope: scope, inboxClass: showsFocusedOther ? inboxClass : nil, filter: filter)
    }

    public func reload() {
        switch scope {
        case .allAccounts: folderKind = nil
        case .folder(let id): folderKind = store.findFolder(id)?.kind ?? .other
        }
        do {
            show(try store.messages(query, limit: limit))
        } catch {
            failed = true
        }
    }

    /// What `observe` follows: a change of it restarts the observation.
    public var observed: ObservedList {
        ObservedList(query: query, limit: limit)
    }

    public struct ObservedList: Hashable {
        let query: InboxQuery
        let limit: Int
    }

    /// Follows the store until the task is cancelled (the view goes, or the query changes).
    public func observe() async {
        let watched = observed
        for await rows in store.observe(watched.query, limit: watched.limit) {
            guard watched == observed else { return }
            show(rows)
        }
    }

    /// The end of the list was reached: a page more of what the phone holds, else older mail
    /// from the servers while they have any.
    public func loadMore() async {
        guard !isLoadingOlder else { return }
        if shownCount < limit {
            guard serverMayHaveMore else { return }
            let asked = scope
            isLoadingOlder = true
            let more = await olderFetcher(asked)
            isLoadingOlder = false
            guard asked == scope else { return }
            serverMayHaveMore = more
        }
        limit += Self.page
        reload()
    }

    private func listChosen() {
        dropsHidden = true
        startOver()
        dropsHidden = false
    }

    private func startOver() {
        limit = Self.page
        serverMayHaveMore = true
        reload()
    }

    private func show(_ rows: [MessageRow]) {
        shownCount = rows.count
        failed = false
        let before = sections.flatMap(\.rows)
        let rows = keepingTheOpenConversation(rows, before: before)
        sections = DaySections.group(rows, now: now(), calendar: calendar)
        selected = PaneSelection.following(selected, old: before.map(\.id), new: rows.map(\.id))
    }

    /// The open conversation stays in view while it is read: a reply to it moves the selection to its
    /// new newest row, and a message that leaves a filtered list only because it was read or flagged
    /// meanwhile (opening it marks it read) stays until another is opened. Moving it to another folder,
    /// or to Other or Focused, still takes it out.
    private func keepingTheOpenConversation(_ rows: [MessageRow], before: [MessageRow]) -> [MessageRow] {
        guard let open = selected, !rows.contains(where: { $0.id == open }),
            let old = before.first(where: { $0.id == open }) else { return rows }
        if let newest = rows.first(where: { $0.threadID == old.threadID && $0.accountID == old.accountID }) {
            selected = newest.id
            return rows
        }
        guard filter != .all, !dropsHidden, var kept = (try? store.message(open)) ?? nil,
            kept.folderID == old.folderID, !showsFocusedOther || kept.inboxClass == old.inboxClass
        else { return rows }
        kept.threadCount = old.threadCount
        var shown = rows
        shown.insert(kept, at: shown.firstIndex { $0.date < kept.date } ?? shown.endIndex)
        return shown
    }

    /// The time or day a row shows.
    public func label(_ row: MessageRow) -> String {
        DaySections.rowLabel(row.date, now: now(), calendar: calendar)
    }

    /// Delete the row's whole conversation (its messages in this folder): to Trash, or for good
    /// from Trash; queued for the server.
    public func swipeLeft(_ message: MessageID) {
        var broke = false
        do {
            if let row = try store.message(message) {
                try Conversation.apply(Conversation.inFolder(of: row, store: store), store: store) { .delete($0) }
            }
        } catch {
            broke = true
        }
        reload()
        if broke { failed = true }
    }

    public func swipeRight(_ message: MessageID) {
        guard let row = (try? store.message(message)) ?? nil else { return }
        perform(.setFlagged(message, !row.isFlagged))
    }

    public func perform(_ action: MailAction) {
        var broke = false
        do {
            try store.apply(action)
        } catch {
            broke = true
        }
        reload()
        if broke { failed = true }
    }

    public func refresh() async {
        isRefreshing = true
        await refresher()
        isRefreshing = false
        reload()
    }
}
