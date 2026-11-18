// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import Testing

@testable import OutwrightUI

@MainActor @Suite struct SearchModelTests {
    private func recents(_ values: [String] = []) -> RecentSearches {
        let defaults = UserDefaults(suiteName: "search-\(UUID().uuidString)") ?? .standard
        let recents = RecentSearches(defaults: defaults)
        for value in values.reversed() { recents.add(value) }
        return recents
    }

    private func withAttachment(subject: String, file: String) throws -> Data {
        try MIMEWriter.write(
            OutgoingMessage(
                from: Address(name: "Bo", email: "bo@example.org"), to: [Address(name: nil, email: "anna@example.org")],
                cc: [], bcc: [], subject: subject, textBody: "Se bilagan.", htmlBody: nil,
                attachments: [
                    Attachment(filename: file, mimeType: "application/pdf", contentID: nil, isInline: false,
                               data: Data("%PDF-1.4".utf8))
                ],
                inReplyTo: nil, references: [], date: Date(timeIntervalSince1970: 1_800_000_000),
                messageID: "a@example.org"),
            includeBcc: false)
    }

    @Test func emptyQueryShowsRecentAndPeople() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "Protokoll")
        try box.add(anna, uid: 2, from: "bo@example.org", subject: "Kallelse")
        try box.add(anna, uid: 3, from: "carl@example.org", subject: "Lunch")
        let model = SearchModel(store: box.store, recents: recents(["protokoll", "budget"]), debounce: .zero)
        #expect(model.query.isEmpty)
        #expect(model.recentSearches == ["protokoll", "budget"])
        #expect(model.frequentPeople.map(\.email) == ["bo@example.org", "carl@example.org"])
        #expect(model.results.isEmpty)
    }

    @Test func typingFindsMessagesAndSubmitRemembersTheSearch() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, from: "bo@example.org", subject: "Kallelse till möte")
        try box.add(anna, uid: 2, subject: "Lunch")
        let model = SearchModel(store: box.store, recents: recents(), debounce: .zero)
        model.query = "kall"
        await model.settled()
        #expect(model.results.compactMap(\.message).map(\.id) == [id])
        await model.submit()
        #expect(model.recentSearches == ["kall"])
    }

    @Test func filesChipShowsAttachments() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 1, subject: "Kallelse", body: try withAttachment(subject: "Kallelse", file: "dagordning.pdf"))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
        let model = SearchModel(store: box.store, recents: recents(), debounce: .zero)
        model.query = "kallelse"
        model.chip = .files
        await model.settled()
        #expect(model.results.map(\.fileName) == ["dagordning.pdf"])
        model.chip = .mail
        await model.settled()
        #expect(model.results.compactMap(\.message).map(\.id) == [id])
        #expect(model.results.allSatisfy { $0.fileName == nil })
        model.chip = .people
        await model.settled()
        #expect(model.results.compactMap(\.person).map(\.emails) == [["bo@example.org"]])
    }

    @Test func boldRangesForMatch() {
        let text = "Sv: Kallelse Delregionalt möte"
        let words = SearchModel.matchRanges(in: text, query: "kall").map { String(text[$0]) }
        #expect(words == ["Kall"])
        #expect(SearchModel.matchRanges(in: text, query: "möte del").map { String(text[$0]) } == ["Del", "möte"])
        #expect(SearchModel.matchRanges(in: text, query: "lse").isEmpty)
        let bold = SearchModel.highlighted(text, query: "kall")
        let runs = bold.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(runs.map { String(bold[$0.range].characters) } == ["Kall"])
    }

    @Test func aStaleScanNeverOverwritesANewerQuery() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        for (uid, subject) in [(UInt32(1), "Kallelse"), (2, "Lunch")] {
            let id = try box.add(anna, uid: uid, subject: subject, body: try withAttachment(subject: subject, file: "\(subject).pdf"))
            var row = try #require(try box.store.message(id))
            row.hasAttachment = true
            _ = try box.store.upsert([row])
        }
        let model = SearchModel(
            store: box.store, recents: recents(), debounce: .zero,
            scanFiles: { store, rows in
                if rows.contains(where: { $0.subject == "Kallelse" }) { try? await Task.sleep(for: .milliseconds(300)) }
                return SearchModel.attachmentFiles(store, rows)
            })
        model.chip = .files
        model.query = "kallelse"
        try await Task.sleep(for: .milliseconds(50))
        model.query = "lunch"
        await model.settled()
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.results.map(\.fileName) == ["Lunch.pdf"])
    }

    /// A message deleted or moved while its undo waits is left out of the results, mail and files
    /// alike; undone, it comes back.
    @Test func stagedMessagesAreLeftOut() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, subject: "Kallelse", body: try withAttachment(subject: "Kallelse", file: "Kallelse.pdf"))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
        let pending = PendingMail(store: box.store)
        let model = SearchModel(store: box.store, recents: recents(), debounce: .zero, staged: pending)
        model.query = "kallelse"
        await model.settled()
        #expect(model.results.compactMap(\.message).map(\.id) == [id])
        #expect(model.results.compactMap(\.fileName) == ["Kallelse.pdf"])
        pending.stage([.delete(id)], hiding: [id], text: "Deleted")
        #expect(model.results.compactMap(\.message).isEmpty)
        #expect(model.results.compactMap(\.fileName).isEmpty)
        pending.undo()
        #expect(model.results.compactMap(\.message).map(\.id) == [id])
    }

    @Test func typingWaitsForAPause() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "Kallelse")
        let model = SearchModel(store: box.store, recents: recents(), debounce: .milliseconds(200))
        model.query = "kall"
        #expect(model.results.isEmpty)
        await model.settled()
        #expect(model.results.compactMap(\.message).count == 1)
    }

    @Test func openedResultsShowBeforeTyping() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, subject: "Kallelse")
        let shared = recents()
        let model = SearchModel(store: box.store, recents: shared, debounce: .zero)
        model.opened(id)
        let again = SearchModel(store: box.store, recents: shared, debounce: .zero)
        #expect(again.recentItems.map(\.id) == [id])
    }

    @Test func anOpenedResultIsARecentItemAtOnce() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let first = try box.add(anna, uid: 1, subject: "Kallelse")
        let second = try box.add(anna, uid: 2, subject: "Protokoll")
        let model = SearchModel(store: box.store, recents: recents(), debounce: .zero)
        model.opened(first)
        model.opened(second)
        #expect(model.recentItems.map(\.id) == [second, first])
    }

    @Test func aRecentItemThatIsGoneLeavesWhenTheQueryIsCleared() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(anna, uid: 1, subject: "Kallelse")
        let shared = recents()
        shared.addItem(id)
        let model = SearchModel(store: box.store, recents: shared, debounce: .zero)
        #expect(model.recentItems.map(\.id) == [id])
        try box.store.removeMessage(id)
        model.query = "kall"
        await model.settled()
        model.query = ""
        await model.settled()
        #expect(model.recentItems.isEmpty)
    }

    @Test func mailBroughtFromTheServerGoesWhenSearchCloses() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let store = box.store
        let model = SearchModel(
            store: store, recents: recents(), debounce: .zero,
            searchServer: { _ in
                let row = MessageRow(
                    id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: 77, threadID: ThreadID(raw: "old"),
                    from: Address(name: "Bo", email: "bo@example.org"), to: [], cc: [], subject: "Gammal kallelse",
                    preview: "", date: Date(timeIntervalSince1970: 1_700_000_000), isRead: true, isFlagged: false,
                    hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
                return (try? store.upsert([row])) ?? []
            })
        model.query = "gammal"
        await model.submit()
        let found = try #require(model.results.compactMap(\.message).first)
        #expect(found.subject == "Gammal kallelse")
        model.close()
        #expect(try store.message(found.id) == nil)
    }

    /// Search as the servers answer it: two old messages brought in, uids 77 and 78.
    private func broughtIn(_ box: inout Mailbox) throws -> SearchModel {
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let store = box.store
        let model = SearchModel(
            store: store, recents: recents(), debounce: .zero,
            searchServer: { _ in
                let rows = [UInt32(77), 78].map { uid in
                    MessageRow(
                        id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: uid,
                        threadID: ThreadID(raw: "old\(uid)"), from: Address(name: "Bo", email: "bo@example.org"),
                        to: [], cc: [], subject: "Gammal kallelse \(uid)", preview: "",
                        date: Date(timeIntervalSince1970: 1_700_000_000), isRead: true, isFlagged: false,
                        hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
                }
                return (try? store.upsert(rows)) ?? []
            })
        return model
    }

    @Test func broughtInMailThatWasOpenedStaysWhenSearchCloses() async throws {
        var box = try Mailbox()
        let model = try broughtIn(&box)
        model.query = "gammal"
        await model.submit()
        let found = model.results.compactMap(\.message)
        try #require(found.count == 2)
        model.opened(found[0].id)
        model.close()
        #expect(try box.store.message(found[0].id) != nil, "opened from search: the message view shows it")
        #expect(try box.store.message(found[1].id) == nil)
    }

    @Test func broughtInMailWithAChangeWaitingStaysWhenSearchCloses() async throws {
        var box = try Mailbox()
        let model = try broughtIn(&box)
        model.query = "gammal"
        await model.submit()
        let found = model.results.compactMap(\.message)
        try #require(found.count == 2)
        try box.store.apply(.setFlagged(found[1].id, true))
        model.close()
        #expect(try box.store.message(found[1].id) != nil, "its change still has to reach the server")
        #expect(try box.store.message(found[0].id) == nil)
    }

    // MARK: - People, events and suggestions

    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, inDays days: Double, attendees: [Attendee] = []) -> EventDetails {
        let start = Self.now.addingTimeInterval(days * 86_400)
        return EventDetails(
            title: title, start: .utc(start), end: .utc(start.addingTimeInterval(3_600)), attendees: attendees)
    }

    private func model(_ box: Mailbox) -> SearchModel {
        SearchModel(store: box.store, recents: recents(), debounce: .zero, now: { Self.now })
    }

    private enum Kind: Equatable { case person, event, file, message, suggestion }

    private func kinds(_ results: [SearchResult]) -> [Kind] {
        results.map { result in
            switch result {
            case .person: .person
            case .event: .event
            case .file: .file
            case .message: .message
            case .suggestion: .suggestion
            }
        }
    }

    @Test func suggestionsComeFirstThenGroupedSections() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true, calDAV: true)
        try box.addContact(anna, ContactDetails(givenName: "Persson", emails: [Labeled(label: "", value: "p@example.org")]))
        try box.addEvent(anna, event("Personalmöte", inDays: 1), now: Self.now)
        let id = try box.add(
            anna, uid: 1, subject: "Personal", body: try withAttachment(subject: "Personal", file: "personal.pdf"))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
        try box.add(anna, uid: 2, subject: "Performance")
        let search = model(box)
        search.query = "per"
        await search.settled()
        #expect(kinds(search.results) == [.suggestion, .suggestion, .person, .message, .message, .event, .file])
        #expect(search.results.compactMap(\.suggestion) == ["performance", "personal"])
        #expect(search.sections.map(\.kind) == [.suggestions, .people, .messages, .events, .files])
        #expect(search.sections.allSatisfy { !$0.hasMore })
    }

    @Test func allCapsPeopleEventsAndSuggestionsAtThree() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true, calDAV: true)
        for index in 1...5 {
            try box.addContact(
                anna, ContactDetails(givenName: "Möte\(index)", emails: [Labeled(label: "", value: "m\(index)@example.org")]))
            try box.addEvent(anna, event("Möte \(index)", inDays: Double(index)), now: Self.now)
            try box.add(anna, uid: UInt32(index), subject: "möte\(index)ord")
        }
        let search = model(box)
        search.query = "möte"
        await search.settled()
        let found = kinds(search.results)
        #expect(found.filter { $0 == .person }.count == 3)
        #expect(found.filter { $0 == .event }.count == 3)
        #expect(found.filter { $0 == .suggestion }.count == 3)
        search.chip = .people
        await search.settled()
        #expect(search.results.compactMap(\.person).filter { $0.contact != nil }.count == 5)
    }

    @Test func allCapsEachSectionAndSaysThereIsMore() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true, calDAV: true)
        for index in 1...5 {
            try box.addContact(
                anna,
                ContactDetails(givenName: "Möte\(index)", emails: [Labeled(label: "", value: "m\(index)@example.org")]))
            try box.addEvent(anna, event("Möte \(index)", inDays: Double(index)), now: Self.now)
            try box.add(anna, uid: UInt32(index), subject: "möte\(index)ord")
        }
        try box.add(anna, uid: 9, subject: "möte9 ord")
        let search = model(box)
        search.query = "möte"
        await search.settled()
        let sections = search.sections
        #expect(sections.allSatisfy { $0.results.count <= 3 })
        #expect(sections.first { $0.kind == .messages }?.results.count == 3)
        #expect(sections.filter { $0.kind != .suggestions }.allSatisfy { $0.hasMore })
        search.chip = .events
        await search.settled()
        #expect(search.sections.map(\.kind) == [.events])
        #expect(search.sections.first?.results.count == 5)
        #expect(search.sections.first?.hasMore == false)
    }

    @Test func serverAnswerChangesTheEmptyState() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "Lunch")
        let search = model(box)
        search.query = "zzzz"
        await search.settled()
        #expect(search.emptyState == .pressSearch)
        await search.submit()
        #expect(search.emptyState == .nothingAnywhere)
    }

    @Test func sameContactInTwoAddressBooksIsOneRow() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        let bo = try box.addAccount("bo@example.org", cardDAV: true)
        for account in [anna, bo] {
            try box.addContact(
                account, ContactDetails(givenName: "Maja", emails: [Labeled(label: "", value: "Maja@example.com")]))
        }
        let search = model(box)
        search.query = "maja"
        search.chip = .people
        await search.settled()
        #expect(search.results.compactMap(\.person).count == 1)
    }

    @Test func eventsChipGoesWhenAPersonIsChosen() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "Hej")
        let search = model(box)
        search.chip = .events
        #expect(search.chip == .events)
        #expect(search.choose(SearchPerson(address: Address(name: "Bo", email: "bo@example.org"))))
        #expect(search.chip == .all)
        #expect(!search.offeredChips.contains(.events))
    }

    @Test func contactWithoutAddressIsAPersonWithItsPhoneAsDetail() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.addContact(anna, ContactDetails(givenName: "Rut", phones: [Labeled(label: "", value: "070 111")]))
        try box.addContact(anna, ContactDetails(organization: "Rutverket"))
        let search = model(box)
        search.query = "rut"
        await search.settled()
        let people = search.results.compactMap(\.person)
        #expect(people.map(\.name) == ["Rut", "Rutverket"])
        #expect(people.map(\.detail) == ["070 111", "Rutverket"])
        #expect(people.allSatisfy { $0.emails.isEmpty && $0.contact != nil })
    }

    @Test func correspondentWhoIsAContactIsOneRow() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", cardDAV: true)
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "Hej")
        try box.add(anna, uid: 2, from: "bosse@example.org", subject: "Hej")
        try box.addContact(
            anna,
            ContactDetails(
                givenName: "Bo", familyName: "Berg",
                emails: [Labeled(label: "", value: "bo@example.org"), Labeled(label: "", value: "bo@work.example")]))
        let search = model(box)
        search.query = "bo"
        search.chip = .people
        await search.settled()
        let people = search.results.compactMap(\.person)
        #expect(people.map(\.name) == ["Bo Berg", "Bo"])
        #expect(people.first?.emails == ["bo@example.org", "bo@work.example"])
        #expect(people.last?.emails == ["bosse@example.org"])
        #expect(people.last?.contact == nil)
    }

    @Test func eventsOnlyUnderAll() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org", calDAV: true)
        try box.addEvent(anna, event("Styrelsemöte", inDays: 2), now: Self.now)
        let search = model(box)
        search.query = "styrelse"
        await search.settled()
        #expect(search.results.compactMap(\.event).map(\.occurrence.details.title) == ["Styrelsemöte"])
        for chip in [SearchChip.mail, .people, .files] {
            search.chip = chip
            await search.settled()
            #expect(search.results.compactMap(\.event).isEmpty, "\(chip)")
        }
    }

    @Test func suggestionKeepsTheEarlierWords() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "årlig performance")
        let search = model(box)
        search.query = "årlig per"
        await search.settled()
        #expect(search.results.compactMap(\.suggestion) == ["årlig performance"])
    }

    // MARK: - A person's mail, filters and the servers

    private actor Asked {
        var queries: [ServerQuery] = []
        func add(_ query: ServerQuery) { queries.append(query) }
    }

    private var bo: SearchPerson {
        SearchPerson(name: "Bo", emails: ["bo@example.org"], detail: "bo@example.org", contact: nil)
    }

    private func subjects(_ model: SearchModel) -> [String] {
        model.results.compactMap(\.message).map(\.subject)
    }

    @Test func choosingAPersonShowsTheirMailFromThenTo() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "från bo")
        try box.add(anna, .sent, uid: 2, from: "anna@example.org", subject: "till bo", to: ["bo@example.org"])
        try box.add(anna, uid: 3, from: "carl@example.org", subject: "från carl")
        let search = model(box)
        #expect(search.choose(bo))
        await search.settled()
        #expect(search.token == bo)
        #expect(search.direction == .from)
        #expect(subjects(search) == ["från bo"])
        #expect(search.showsFilterRow)
        search.direction = .to
        await search.settled()
        #expect(subjects(search) == ["till bo"])
        search.removeToken()
        await search.settled()
        #expect(search.token == nil)
        #expect(search.results.isEmpty)
    }

    @Test func tokenWithWordsNarrowsTheirMail() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "budget")
        try box.add(anna, uid: 2, from: "bo@example.org", subject: "lunch")
        try box.add(anna, uid: 3, from: "carl@example.org", subject: "budget carl")
        let search = model(box)
        _ = search.choose(bo)
        search.query = "budg"
        await search.settled()
        #expect(subjects(search) == ["budget"])
    }

    @Test func personWithoutAddressIsNotATokenAndSaysSo() throws {
        let search = SearchModel(store: try MailStore(path: nil), recents: recents(), debounce: .zero)
        let rut = SearchPerson(name: "Rut", emails: [], detail: "070 111", contact: ContactID(raw: 1))
        #expect(!search.choose(rut))
        #expect(search.token == nil)
    }

    @Test func tokenChipsNarrowToThePerson() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 1, from: "bo@example.org", subject: "Kallelse",
            body: try withAttachment(subject: "Kallelse", file: "dagordning.pdf"))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
        try box.add(anna, uid: 2, from: "carl@example.org", subject: "Kallelse carl")
        let search = model(box)
        _ = search.choose(bo)
        search.chip = .people
        await search.settled()
        #expect(search.results.compactMap(\.person) == [bo])
        search.chip = .files
        await search.settled()
        #expect(search.results.map(\.fileName) == ["dagordning.pdf"])
        search.chip = .mail
        await search.settled()
        #expect(subjects(search) == ["Kallelse"])
    }

    @Test func filtersCombineAndCount() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "möte oläst")
        try box.add(anna, uid: 2, subject: "möte läst flaggad", read: true, flagged: true)
        try box.add(anna, uid: 3, subject: "möte oläst flaggad", flagged: true)
        let search = model(box)
        search.query = "möte"
        #expect(!search.showsFilterRow)
        await search.submit()
        #expect(search.showsFilterRow)
        search.filter.unread = true
        await search.settled()
        #expect(Set(subjects(search)) == ["möte oläst", "möte oläst flaggad"])
        search.filter.flagged = true
        await search.settled()
        #expect(subjects(search) == ["möte oläst flaggad"])
        #expect(search.filter.count == 2)
    }

    @Test func olderThanSixMonthsAsksTheServersAtOnceWithBefore() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "budget ny", date: Self.now.addingTimeInterval(-86_400))
        try box.add(anna, uid: 2, subject: "budget gammal", date: Self.now.addingTimeInterval(-300 * 86_400))
        let asked = Asked()
        let search = SearchModel(
            store: box.store, recents: recents(), debounce: .zero,
            searchServer: { query in await asked.add(query); return [] }, now: { Self.now })
        search.query = "budget"
        await search.settled()
        search.olderThanSixMonths = true
        await search.settled()
        let queries = await asked.queries
        let cut = try #require(Calendar.current.date(byAdding: .month, value: -6, to: Self.now))
        #expect(queries == [ServerQuery(text: "budget", before: cut)])
        #expect(subjects(search) == ["budget gammal"])
    }

    @Test func tokenAsksTheServersPerDirectionOnce() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let asked = Asked()
        let search = SearchModel(
            store: box.store, recents: recents(), debounce: .zero,
            searchServer: { query in await asked.add(query); return [] }, now: { Self.now })
        _ = search.choose(bo)
        await search.settled()
        search.direction = .to
        await search.settled()
        search.direction = .from
        await search.settled()
        let queries = await asked.queries
        #expect(queries == [
            ServerQuery(text: "", people: ["bo@example.org"], direction: .from),
            ServerQuery(text: "", people: ["bo@example.org"], direction: .to)
        ])
    }

    @Test func closeWhileAServerSearchRunsStillRemovesItsMail() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let store = box.store
        let search = SearchModel(
            store: store, recents: recents(), debounce: .zero,
            searchServer: { _ in
                try? await Task.sleep(for: .milliseconds(200))
                let row = MessageRow(
                    id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: 90, threadID: ThreadID(raw: "late"),
                    from: Address(name: "Bo", email: "bo@example.org"), to: [], cc: [], subject: "Sent svar",
                    preview: "", date: Date(timeIntervalSince1970: 1_600_000_000), isRead: true, isFlagged: false,
                    hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
                return (try? store.upsert([row])) ?? []
            })
        _ = search.choose(bo)
        try await Task.sleep(for: .milliseconds(50))
        search.close()
        await search.settled()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.search("sent svar", limit: 5).isEmpty)
    }

    @Test func fileHitOpensItsAttachmentAndNothingOnceItChanged() throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 1, subject: "Kallelse", body: try withAttachment(subject: "Kallelse", file: "dagordning.pdf"))
        let row = try #require(try box.store.message(id))
        let hit = try #require(SearchModel.attachmentFiles(box.store, [row]).first)
        let attachment = try #require(SearchModel.attachment(hit, in: box.store))
        #expect(attachment.filename == "dagordning.pdf")
        #expect(attachment.data == Data("%PDF-1.4".utf8))
        var renamed = hit
        renamed.name = "other.pdf"
        #expect(SearchModel.attachment(renamed, in: box.store) == nil)
        var outside = hit
        outside.index = 7
        #expect(SearchModel.attachment(outside, in: box.store) == nil)
    }

    // MARK: - Review fixes

    @Test func aPersonsServerHitsKeepFromAndToApart() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let inbox = try box.folder(anna, .inbox)
        let store = box.store
        let search = SearchModel(
            store: store, recents: recents(), debounce: .zero,
            searchServer: { _ in
                // IMAP FROM matches a substring: jbo@ comes back for bo@.
                let row = MessageRow(
                    id: MessageID(raw: 0), accountID: anna.id, folderID: inbox.id, uid: 91, threadID: ThreadID(raw: "j"),
                    from: Address(name: "J", email: "jbo@example.org"), to: [], cc: [], subject: "från jbo",
                    preview: "", date: Date(timeIntervalSince1970: 1_600_000_000), isRead: true, isFlagged: false,
                    hasAttachment: false, isInvitation: false, inboxClass: .focused, hasBody: false, threadCount: 1)
                return (try? store.upsert([row])) ?? []
            }, now: { Self.now })
        try box.add(anna, uid: 1, from: "bo@example.org", subject: "från bo")
        _ = search.choose(bo)
        await search.settled()
        #expect(subjects(search) == ["från bo"])
    }

    @Test func filtersGoWhenTheirRowDoes() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "möte", read: true)
        let search = model(box)
        search.query = "möte"
        await search.submit()
        search.filter.unread = true
        await search.settled()
        #expect(subjects(search).isEmpty)
        search.query = ""
        search.query = "möte"
        await search.settled()
        #expect(search.filter == SearchFilter())
        #expect(subjects(search) == ["möte"])
        _ = search.choose(bo)
        search.filter.flagged = true
        search.removeToken()
        #expect(search.filter == SearchFilter())
    }

    @Test func filesAreNotFiltered() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let id = try box.add(
            anna, uid: 1, subject: "Kallelse", read: true,
            body: try withAttachment(subject: "Kallelse", file: "dagordning.pdf"))
        var row = try #require(try box.store.message(id))
        row.hasAttachment = true
        _ = try box.store.upsert([row])
        let search = model(box)
        search.query = "kallelse"
        await search.submit()
        search.filter.unread = true
        search.chip = .files
        await search.settled()
        #expect(search.results.map(\.fileName) == ["dagordning.pdf"])
    }

    @Test func filterRowOnlyOverAllAndMail() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "möte")
        let search = model(box)
        search.query = "möte"
        await search.submit()
        #expect(search.showsFilterRow)
        search.chip = .people
        #expect(!search.showsFilterRow)
        search.chip = .files
        #expect(!search.showsFilterRow)
        search.chip = .mail
        #expect(search.showsFilterRow)
    }

    @Test func suggestionKeepsEverythingBeforeTheLastWord() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        try box.add(anna, uid: 1, subject: "bank")
        let search = model(box)
        search.query = "foo bar-ba"
        await search.settled()
        #expect(search.results.compactMap(\.suggestion) == ["foo bar-bank"])
    }

    @Test func aSecondSubmitWhileAskingAsksOnce() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let asked = Asked()
        let search = SearchModel(
            store: box.store, recents: recents(), debounce: .zero,
            searchServer: { query in
                await asked.add(query)
                try? await Task.sleep(for: .milliseconds(100))
                return []
            }, now: { Self.now })
        search.query = "budget"
        search.olderThanSixMonths = true
        async let first: Void = search.submit()
        async let second: Void = search.submit()
        _ = await (first, second)
        await search.settled()
        #expect(await asked.queries.count == 1)
        #expect(!search.isAskingServers)
    }

    @Test func nothingIsAskedAfterClose() async throws {
        var box = try Mailbox()
        _ = try box.addAccount("anna@example.org")
        let asked = Asked()
        let search = SearchModel(
            store: box.store, recents: recents(), debounce: .zero,
            searchServer: { query in
                await asked.add(query)
                try? await Task.sleep(for: .milliseconds(100))
                return []
            }, now: { Self.now })
        _ = search.choose(bo)
        search.direction = .to
        search.close()
        await search.settled()
        #expect(await asked.queries.count <= 1)
    }
}

