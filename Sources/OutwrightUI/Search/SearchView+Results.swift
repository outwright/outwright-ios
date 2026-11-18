// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

extension SearchView {
    // MARK: - Results

    var results: some View {
        // A new chip is a new list, which starts at the top.
        resultList.id(model.chip)
    }

    private var resultList: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.results) { result in
                        row(result)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
            if model.isAskingServers {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .opensAttachment($opening)
        .overlay {
            if model.emptyState != .hasResults {
                ContentUnavailableView {
                    Label { Text(ui: "No results") } icon: { Image(systemName: Icons.search) }
                } description: {
                    if model.emptyState == .nothingAnywhere {
                        Text(ui: "No results on this phone or the server")
                    } else {
                        Text(ui: "Press Search to look on the server too.")
                    }
                }
            }
        }
    }

    /// The group's name, and under All a See all that picks that kind's chip.
    @ViewBuilder
    private func sectionHeader(_ section: SearchSection) -> some View {
        if let chip = Self.chip(section.kind), model.chip == .all, model.token == nil {
            HStack {
                SectionHeader(Self.title(chip))
                Spacer()
                if section.hasMore {
                    Button {
                        model.chip = chip
                    } label: {
                        Text(ui: "See all")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search.seeAll")
                }
            }
        }
    }

    private static func chip(_ kind: SearchSection.Kind) -> SearchChip? {
        switch kind {
        case .suggestions: nil
        case .people: .people
        case .messages: .mail
        case .events: .events
        case .files: .files
        }
    }

    // Each row sets its own identifiers: one set around a row would win over those of the buttons
    // inside it (the person row's card button).
    @ViewBuilder
    private func row(_ result: SearchResult) -> some View {
        switch result {
        case .person(let person):
            SearchPersonRow(
                person: person, query: model.query,
                choose: {
                    if model.choose(person) {
                        model.query = ""
                    } else {
                        openCard(person)
                    }
                },
                openCard: { openCard(person) })
        case .event(let event):
            Button {
                app.pendingEvent = EventRequest(event: event.id, occurrence: event.occurrence.recurrenceID)
                app.searchHandedOver()
            } label: {
                SearchEventRow(event: event, query: model.query)
            }
            .accessibilityIdentifier("search.event")
        case .file(let file):
            Button {
                openFile(file)
            } label: {
                HStack(spacing: 16) {
                    FileIcon(name: file.name)
                    twoLines(SearchModel.highlighted(file.name, query: model.query), byline(file.message))
                }
            }
            .accessibilityIdentifier("search.result")
        case .message(let message):
            messageRow(message)
                .accessibilityIdentifier("search.result")
        case .suggestion(let text):
            Button {
                model.query = text
                Task { await model.submit() }
            } label: {
                SearchSuggestionRow(text: text, query: model.query)
            }
            .accessibilityIdentifier("search.suggestion")
        }
    }

    /// A message hit as the inbox shows it, with its folder.
    private func messageRow(_ message: MessageRow) -> some View {
        Button {
            open(message)
        } label: {
            MessageRowView(
                row: message,
                label: DaySections.rowLabel(message.date, now: Date(), calendar: .autoupdatingCurrent),
                folderName: model.folderName(message.folderID))
        }
    }

    private func openCard(_ person: SearchPerson) {
        app.pendingPerson = PersonRequest(address: person.address, contact: person.contact)
        app.searchHandedOver()
    }

    private func openFile(_ file: FileHit) {
        guard let attachment = SearchModel.attachment(file, in: app.store) else {
            open(file.message)
            return
        }
        opening = ShownAttachment(attachment: attachment)
    }

    func twoLines(_ first: AttributedString, _ second: Text) -> some View {
        SearchTwoLines(first: first, second: second)
    }
}
