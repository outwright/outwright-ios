// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

extension SearchView {
    // MARK: - Results

    var results: some View {
        List {
            ForEach(model.results) { result in
                row(result)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
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
            if model.results.isEmpty && !model.isAskingServers {
                ContentUnavailableView {
                    Label { Text(ui: "No results") } icon: { Image(systemName: Icons.search) }
                } description: {
                    Text(ui: "Press Search to look on the server too.")
                }
            }
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
                app.isSearching = false
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

    /// A person's mail as the inbox shows it, with its folder; other mail as a found line.
    private func messageRow(_ message: MessageRow) -> some View {
        Button {
            open(message)
        } label: {
            if model.token != nil {
                MessageRowView(
                    row: message,
                    label: DaySections.rowLabel(message.date, now: Date(), calendar: .autoupdatingCurrent),
                    folderName: model.folderName(message.folderID))
            } else {
                HStack(spacing: 16) {
                    MailIcon()
                    twoLines(SearchModel.highlighted(Self.subject(message), query: model.query), byline(message))
                }
            }
        }
    }

    private func openCard(_ person: SearchPerson) {
        app.pendingPerson = PersonRequest(address: person.address, contact: person.contact)
        app.isSearching = false
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
