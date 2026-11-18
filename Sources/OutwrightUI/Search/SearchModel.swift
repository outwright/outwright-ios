// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightMIME
public import OutwrightModel
public import OutwrightStore
public import OutwrightSync

/// The chips under the search field.
public enum SearchChip: CaseIterable, Sendable {
    case all, mail, people, events, files
}

/// One group of the results.
public struct SearchSection: Identifiable, Sendable {
    public enum Kind: Hashable, Sendable { case suggestions, people, messages, events, files }
    public let kind: Kind
    public let results: [SearchResult]
    public let hasMore: Bool
    public var id: Kind { kind }
}

/// The last searches the owner made and the messages opened from search, newest first, kept on
/// this phone (`UserDefaults`; no message text, only local ids).
public struct RecentSearches: @unchecked Sendable {
    static let key = "recentSearches"
    static let itemsKey = "recentSearchItems"
    static let limit = 10
    static let itemLimit = 5
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var all: [String] {
        Array((defaults.stringArray(forKey: Self.key) ?? []).prefix(Self.limit))
    }

    public func add(_ search: String) {
        let text = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !text.isEmpty else { return }
        let rest = all.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        defaults.set(Array(([text] + rest).prefix(Self.limit)), forKey: Self.key)
    }

    public var items: [MessageID] {
        let raw = defaults.array(forKey: Self.itemsKey) as? [Int64] ?? []
        return raw.prefix(Self.itemLimit).map(MessageID.init(raw:))
    }

    public func addItem(_ id: MessageID) {
        let rest = items.map(\.raw).filter { $0 != id.raw }
        defaults.set(Array(([id.raw] + rest).prefix(Self.itemLimit)), forKey: Self.itemsKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.itemsKey)
    }
}

/// Search: before typing, frequent people, recent items and recent searches; while typing (after
/// a short pause), what the phone holds (full-text), with attachments read off the main actor; on
/// submit, also the servers for mail older than the sync window, which goes again when search closes.
@Observable @MainActor
public final class SearchModel {
    nonisolated static let localLimit = 200
    /// Most people, events and suggestions under All.
    nonisolated static let allLimit = 3
    /// Most people under People.
    nonisolated static let peopleLimit = 50
    public typealias FileScan = @Sendable (MailStore, [MessageRow]) async -> [FileHit]
    public typealias ServerSearch = @Sendable (ServerQuery) async -> [MessageID]

    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Back to the start: the recent items as they now stand (one may have been opened or deleted).
            if query.isEmpty {
                reloadRecentItems()
                submitted = false
                // The filter row goes with nothing left to filter, and so do its filters.
                if token == nil { filter = SearchFilter() }
            }
            schedule(after: debounce)
        }
    }
    /// The person whose mail is shown (From / To), the typed words narrowing it.
    public private(set) var token: SearchPerson?
    public var direction: PersonDirection = .from {
        didSet { if direction != oldValue { changedAsking() } }
    }
    public var filter = SearchFilter() {
        didSet {
            guard filter != oldValue else { return }
            if filter.olderThan == oldValue.olderThan {
                schedule(after: .zero)
            } else {
                changedAsking()
            }
        }
    }
    /// Only mail older than six months: the servers are asked at once.
    public var olderThanSixMonths: Bool {
        get { filter.olderThan != nil }
        set { filter.olderThan = newValue ? Calendar.current.date(byAdding: .month, value: -6, to: now()) : nil }
    }
    /// A search was submitted (the Search key) since the field was last empty.
    public private(set) var submitted = false
    /// The filters are offered over a list of mail: a person's, or a submitted search's.
    public var showsFilterRow: Bool { (token != nil || submitted) && (chip == .all || chip == .mail) }
    public var chip: SearchChip = .all {
        didSet { if chip != oldValue { schedule(after: .zero) } }
    }
    public private(set) var recentSearches: [String]
    public private(set) var recentItems: [MessageRow] = []
    public private(set) var frequentPeople: [Address]
    /// Everything found, staged messages too.
    var allResults: [SearchResult] = []
    /// What was found, without the messages (and their files) waiting out an undo.
    public var results: [SearchResult] {
        let hidden = staged?.hidden ?? []
        guard !hidden.isEmpty else { return allResults }
        return allResults.filter { result in
            guard let message = result.message?.id ?? result.file?.message.id else { return true }
            return !hidden.contains(message)
        }
    }
    /// Kinds that have more than the three shown under All.
    var moreFound: Set<SearchSection.Kind> = []
    public internal(set) var isAskingServers = false

    @ObservationIgnored let store: MailStore
    @ObservationIgnored let recents: RecentSearches
    @ObservationIgnored let debounce: Duration
    @ObservationIgnored let scanFiles: FileScan
    @ObservationIgnored let searchServer: ServerSearch?
    @ObservationIgnored let now: @Sendable () -> Date
    /// The deletes and moves waiting out their undo; their messages are left out.
    @ObservationIgnored let staged: PendingMail?
    @ObservationIgnored let people: [Address]
    @ObservationIgnored let ownAddresses: Set<String>
    @ObservationIgnored var serverHits: [ServerQuery: [MessageID]] = [:]
    /// Rows the servers' search brought in; they go when search closes.
    @ObservationIgnored var broughtIn: Set<MessageID> = []
    @ObservationIgnored var pending: Task<Void, Never>?
    /// The servers being asked, when they are.
    @ObservationIgnored var asking: Task<Void, Never>?
    /// Search has closed: what the servers still bring in goes at once.
    @ObservationIgnored var isClosed = false
    @ObservationIgnored private var folderNames: [FolderID: String] = [:]
    @ObservationIgnored var generation = 0

    public convenience init(
        store: MailStore, sync: SyncCoordinator?, recents: RecentSearches = RecentSearches(), staged: PendingMail? = nil
    ) {
        var server: ServerSearch?
        if let sync {
            server = { query in await sync.searchServer(query) }
        }
        self.init(store: store, recents: recents, searchServer: server, staged: staged)
    }

    init(
        store: MailStore, recents: RecentSearches = RecentSearches(), debounce: Duration = .milliseconds(250),
        scanFiles: @escaping FileScan = { store, rows in SearchModel.attachmentFiles(store, rows) },
        searchServer: ServerSearch? = nil, now: @escaping @Sendable () -> Date = { Date() },
        staged: PendingMail? = nil
    ) {
        self.staged = staged
        self.store = store
        self.recents = recents
        self.debounce = debounce
        self.scanFiles = scanFiles
        self.searchServer = searchServer
        self.now = now
        let accounts = (try? store.accounts()) ?? []
        ownAddresses = Set(accounts.map { $0.email.lowercased() })
        people = PeopleIndex.known(store, accounts: accounts)
        frequentPeople = Array(people.prefix(10))
        recentSearches = recents.all
        recentItems = []
        reloadRecentItems()
    }

    /// The chips offered: a person's mail has no events.
    public var offeredChips: [SearchChip] {
        SearchChip.allCases.filter { token == nil || $0 != .events }
    }

    /// The results as groups, in the order suggestions, people, mail, events, files. Under All each
    /// group is cut to three rows and says whether there is more; under a chip it is whole.
    public var sections: [SearchSection] {
        let order: [SearchSection.Kind] = [.suggestions, .people, .messages, .events, .files]
        let capped = chip == .all && token == nil
        return order.compactMap { kind in
            let rows = results.filter { $0.kind == kind }
            guard !rows.isEmpty else { return nil }
            let shown = capped ? Array(rows.prefix(Self.allLimit)) : rows
            let more = capped && (rows.count > Self.allLimit || moreFound.contains(kind))
            return SearchSection(kind: kind, results: shown, hasMore: more && kind != .suggestions)
        }
    }

    /// What the list says when it has nothing to show.
    public enum EmptyState: Sendable { case hasResults, pressSearch, nothingAnywhere }

    public var emptyState: EmptyState {
        guard results.isEmpty, !isAskingServers else { return .hasResults }
        return submitted ? .nothingAnywhere : .pressSearch
    }

    /// The name of a folder, for the rows of a person's mail.
    public func folderName(_ id: FolderID) -> String? {
        if folderNames.isEmpty {
            for account in (try? store.accounts()) ?? [] {
                for folder in (try? store.folders(account.id)) ?? [] { folderNames[folder.id] = folder.name }
            }
        }
        return folderNames[id]
    }

    private func reloadRecentItems() {
        recentItems = recents.items.compactMap { try? store.message($0) }
    }

    /// Waits until the results for the current query and chip are in (for tests and the view).
    public func settled() async {
        if let asking { await asking.value }
        await resultsSettled()
    }

    /// Waits until the results for the current query and chip are in, not for the servers.
    func resultsSettled() async {
        while let task = pending {
            await task.value
            if pending == task { break }
        }
    }

    /// The search is remembered and the servers are asked for older mail.
    public func submit() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recents.add(text)
        recentSearches = recents.all
        submitted = true
        enqueueAsk(serverQuery)
        await asking?.value
        await resultsSettled()
    }

    /// A result was opened: it is shown among the recent items next time.
    public func opened(_ id: MessageID) {
        recents.addItem(id)
        reloadRecentItems()
        // Opened from search: it stays, so the message view has something to show.
        broughtIn.remove(id)
    }

    public func clearRecent() {
        recents.clear()
        recentSearches = []
        recentItems = []
    }

    /// Search closes: the mail the servers' search brought in goes again (unless it was opened or
    /// a change to it still waits for the server), so it does not linger in folder lists.
    public func close() {
        isClosed = true
        pending?.cancel()
        removeBroughtIn()
    }

    /// The mail the servers brought in goes, unless a change to it still waits for the server.
    func removeBroughtIn() {
        let waiting = Set(((try? store.pendingActions()) ?? []).map { Self.message(of: $0.action) })
        for id in broughtIn where !waiting.contains(id) {
            try? store.removeMessage(id)
        }
        broughtIn = []
    }

    /// The person's mail is shown instead of the search; false (and nothing changes) for a person
    /// without an address, whose card opens instead.
    public func choose(_ person: SearchPerson) -> Bool {
        guard !person.emails.isEmpty else { return false }
        token = person
        direction = .from
        if chip == .events { chip = .all }
        changedAsking()
        return true
    }

    public func removeToken() {
        guard token != nil else { return }
        token = nil
        if !submitted { filter = SearchFilter() }
        schedule(after: .zero)
    }

    static func message(of action: MailAction) -> MessageID {
        action.target
    }

    // MARK: - Highlighting

    /// Where the query's words start words of `text` (ignoring case and accents), in order.
    public nonisolated static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        let words = query.split(whereSeparator: \.isWhitespace).prefix(16).map(String.init)
        var ranges: [Range<String.Index>] = []
        for word in words {
            var start = text.startIndex
            var count = 0
            while count < 100,
                let found = text.range(
                    of: word, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                count += 1
                let atWordStart =
                    found.lowerBound == text.startIndex
                    || !(text[text.index(before: found.lowerBound)].isLetter
                        || text[text.index(before: found.lowerBound)].isNumber)
                if atWordStart { ranges.append(found) }
                start = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `text` with the matched words in bold.
    public nonisolated static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for range in matchRanges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}
