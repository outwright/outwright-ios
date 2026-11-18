// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync

/// What one query found on the phone, before the chip picks from it.
struct SearchFound {
    var people: [SearchPerson] = []
    var events: [CalendarEvent] = []
    var messages: [MessageRow] = []
    var files: [FileHit] = []
    var suggestions: [String] = []
}

/// What the store holds for one query, read off the main actor.
struct SearchLocal: Sendable {
    /// The mail matching, as the filter admits it.
    var messages: [MessageRow] = []
    /// The mail matching whatever the filter (files are not filtered); nil when no filter is on.
    var unfiltered: [MessageRow]?
    var contacts: [SearchPerson] = []
    var events: [CalendarEvent] = []
    var suggestions: [String] = []
}

extension SearchModel {
    /// Asks the servers once per query; what they bring in joins the results and goes when search
    /// closes. After search has closed nothing more is asked.
    func ask(_ query: ServerQuery) async {
        guard !isClosed else { return }
        guard let searchServer, serverHits[query] == nil, !query.searchesNothing else {
            schedule(after: .zero)
            await resultsSettled()
            return
        }
        isAskingServers = true
        let found = await searchServer(query)
        isAskingServers = false
        serverHits[query] = found
        broughtIn.formUnion(found)
        if isClosed {
            removeBroughtIn()
            return
        }
        schedule(after: .zero)
        await resultsSettled()
    }

    /// Queues `query` behind any ask under way, so one query is asked once and one at a time.
    func enqueueAsk(_ query: ServerQuery) {
        let previous = asking
        asking = Task { [weak self] in
            await previous?.value
            await self?.ask(query)
        }
    }

    /// What the servers are asked for what is shown now.
    var serverQuery: ServerQuery {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token else { return ServerQuery(text: text, before: filter.olderThan) }
        return ServerQuery(text: text, people: Set(token.emails), direction: direction, before: filter.olderThan)
    }

    /// The person, their direction or the age changed: the list is redone and, for a person or
    /// older mail, the servers asked.
    func changedAsking() {
        schedule(after: .zero)
        guard token != nil || filter.olderThan != nil else { return }
        enqueueAsk(serverQuery)
    }

    func schedule(after delay: Duration) {
        pending?.cancel()
        generation &+= 1
        let wanted = generation
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.update(wanted)
        }
    }

    private func update(_ wanted: Int) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token {
            await updatePerson(token, text, wanted)
            return
        }
        guard !text.isEmpty else {
            allResults = []
            return
        }
        let (store, chip, filter, instant) = (store, chip, filter, now())
        let local = await Task.detached {
            Self.readLocal(store, text, chip: chip, filter: filter, now: instant)
        }.value
        guard wanted == generation, !Task.isCancelled else { return }
        var found = SearchFound()
        found.messages = withServerHits(local.messages, filter: filter) { _ in true }
        if chip == .all || chip == .people {
            found.people = persons(text, contacts: local.contacts, senders: chip == .people ? found.messages : [])
        }
        found.events = local.events
        found.suggestions = local.suggestions
        // Mail first, files as soon as they are read.
        allResults = compose(found)
        guard chip == .all || chip == .files else { return }
        let all = local.unfiltered.map { withServerHits($0, filter: SearchFilter()) { _ in true } } ?? found.messages
        guard let files = await files(of: all, wanted) else { return }
        found.files = files
        allResults = compose(found)
    }

    /// The person's mail (From or To), narrowed by the words and the filter: all of it under All
    /// and Mail, the person under People, its files (whatever the filter) under Files.
    private func updatePerson(_ person: SearchPerson, _ text: String, _ wanted: Int) async {
        let (store, emails, direction, filter) = (store, Set(person.emails), direction, filter)
        let (filtered, unfiltered) = await Task.detached { () -> ([MessageRow], [MessageRow]?) in
            func read(_ narrowing: SearchFilter) -> [MessageRow] {
                (try? store.messages(
                    involving: emails, direction: direction, matching: text, filter: narrowing,
                    limit: SearchModel.localLimit)) ?? []
            }
            return (read(filter), filter == SearchFilter() ? nil : read(SearchFilter()))
        }.value
        guard wanted == generation, !Task.isCancelled else { return }
        // The servers match addresses as substrings (bo@ in jbo@): their hits are checked as the
        // phone's own query checks.
        let isTheirs = { (row: MessageRow) -> Bool in
            switch direction {
            case .from: emails.contains(row.from.email.lowercased())
            case .to: (row.to + row.cc).contains { emails.contains($0.email.lowercased()) }
            }
        }
        switch chip {
        case .all, .mail:
            allResults = withServerHits(filtered, filter: filter, admitting: isTheirs).map(SearchResult.message)
        case .people:
            allResults = [.person(person)]
        case .events:
            allResults = []
        case .files:
            allResults = []
            let all = withServerHits(unfiltered ?? filtered, filter: SearchFilter(), admitting: isTheirs)
            guard let files = await files(of: all, wanted) else { return }
            allResults = files.map(SearchResult.file)
        }
    }

    /// The files of `rows`, read off the main actor; nil when a newer query or chip took over.
    private func files(of rows: [MessageRow], _ wanted: Int) async -> [FileHit]? {
        let attached = rows.filter(\.hasAttachment)
        guard !attached.isEmpty else { return nil }
        let (scan, store) = (scanFiles, store)
        let files = await Task.detached { await scan(store, attached) }.value
        guard wanted == generation, !Task.isCancelled else { return nil }
        return files
    }

    /// The store's part of a query: mail, contacts, events and suggestions (it reads the database:
    /// run it off the main actor).
    nonisolated static func readLocal(
        _ store: MailStore, _ text: String, chip: SearchChip, filter: SearchFilter, now: Date
    ) -> SearchLocal {
        var local = SearchLocal()
        local.messages = (try? store.search(text, filter: filter, limit: localLimit)) ?? []
        if filter != SearchFilter(), chip == .all || chip == .files {
            local.unfiltered = (try? store.search(text, filter: SearchFilter(), limit: localLimit)) ?? []
        }
        if chip == .all || chip == .people {
            local.contacts = ((try? store.searchContacts(text, limit: peopleLimit)) ?? [])
                .map(SearchPerson.init(contact:))
        }
        if chip == .all {
            // One more than shown, to know whether there is more.
            local.events = (try? store.searchEvents(text, now: now, limit: allLimit + 1)) ?? []
            local.suggestions = suggestions(text, in: store, limit: allLimit + 1)
        }
        if chip == .events {
            local.events = (try? store.searchEvents(text, now: now, limit: peopleLimit)) ?? []
        }
        return local
    }

    /// `local` with what the servers brought in for what is shown now, as `filter` and `admitting`
    /// let it through; newest first.
    private func withServerHits(
        _ local: [MessageRow], filter: SearchFilter, admitting: (MessageRow) -> Bool
    ) -> [MessageRow] {
        var messages = local
        var seen = Set(messages.map(\.id))
        for id in serverHits[serverQuery] ?? [] where !seen.contains(id) {
            if let row = try? store.message(id), Self.admits(row, filter), admitting(row) {
                messages.append(row)
                seen.insert(id)
            }
        }
        return messages.sorted { $0.date > $1.date }
    }

    private static func admits(_ row: MessageRow, _ filter: SearchFilter) -> Bool {
        !(filter.unread && row.isRead) && !(filter.flagged && !row.isFlagged)
            && !(filter.attachments && !row.hasAttachment) && filter.olderThan.map { row.date < $0 } ?? true
    }

    private func compose(_ found: SearchFound) -> [SearchResult] {
        switch chip {
        case .all:
            var more = Set<SearchSection.Kind>()
            if found.people.count > Self.allLimit { more.insert(.people) }
            if found.events.count > Self.allLimit { more.insert(.events) }
            if found.suggestions.count > Self.allLimit { more.insert(.suggestions) }
            moreFound = more
            return Array(found.suggestions.prefix(Self.allLimit)).map(SearchResult.suggestion)
                + Array(found.people.prefix(Self.allLimit)).map(SearchResult.person)
                + found.messages.map(SearchResult.message)
                + Array(found.events.prefix(Self.allLimit)).map(SearchResult.event)
                + found.files.map(SearchResult.file)
        case .mail:
            return found.messages.map(SearchResult.message)
        case .people:
            return found.people.map(SearchResult.person)
        case .events:
            return found.events.map(SearchResult.event)
        case .files:
            return found.files.map(SearchResult.file)
        }
    }

    /// The contacts that matched, then people mail was exchanged with whose name or address matches,
    /// then (under People) the senders of the mail found; one row per person, never the owner.
    private func persons(_ text: String, contacts: [SearchPerson], senders: [MessageRow]) -> [SearchPerson] {
        var seen = Set(contacts.flatMap(\.emails)).union(ownAddresses)
        // The owner's own card is no one to find; a person in two address books is one row.
        var known = Set<String>()
        var found: [SearchPerson] = []
        for person in contacts where person.emails.allSatisfy({ !ownAddresses.contains($0) }) {
            guard person.emails.isEmpty || known.isDisjoint(with: person.emails) else { continue }
            known.formUnion(person.emails)
            found.append(person)
        }
        let others = people.filter { PeopleIndex.matches($0, text) } + senders.map(\.from)
        for address in others where found.count < Self.peopleLimit {
            let key = address.email.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            found.append(SearchPerson(address: address))
        }
        return Array(found.prefix(Self.peopleLimit))
    }

    /// Completions of the word being typed (the letters and digits at the end of `text`), with all
    /// that comes before it kept as typed. None once the text ends in anything else.
    nonisolated static func suggestions(_ text: String, in store: MailStore, limit: Int = allLimit) -> [String] {
        var start = text.endIndex
        var count = 0
        while start > text.startIndex, count < 64 {
            let before = text.index(before: start)
            guard text[before].isLetter || text[before].isNumber else { break }
            start = before
            count += 1
        }
        guard start < text.endIndex else { return [] }
        let lead = String(text[..<start])
        let word = String(text[start...])
        return ((try? store.suggestedWords(startingWith: word, limit: limit)) ?? []).map { lead + $0 }
    }

    /// The attachments of the messages whose bodies are on the phone (read and parsed: run it off
    /// the main actor), at most 50.
    nonisolated static func attachmentFiles(_ store: MailStore, _ rows: [MessageRow]) -> [FileHit] {
        var found: [FileHit] = []
        for row in rows where found.count < 50 {
            guard let parsed = (try? store.opened(row.id)).flatMap({ $0 })?.message else { continue }
            for (index, attachment) in parsed.attachments.enumerated()
            where !attachment.isInline && !attachment.filename.isEmpty && found.count < 50 {
                found.append(
                    FileHit(
                        name: attachment.filename, mimeType: attachment.mimeType, size: attachment.data.count,
                        index: index, message: row))
            }
        }
        return found
    }

    /// The attachment a file hit names, read again from its message: nil when the body is gone or
    /// the attachment at that place is no longer the one named.
    nonisolated static func attachment(_ hit: FileHit, in store: MailStore) -> Attachment? {
        guard let parsed = (try? store.opened(hit.message.id)).flatMap({ $0 })?.message,
            parsed.attachments.indices.contains(hit.index)
        else { return nil }
        let attachment = parsed.attachments[hit.index]
        return attachment.filename == hit.name ? attachment : nil
    }
}
