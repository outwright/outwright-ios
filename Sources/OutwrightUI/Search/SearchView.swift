// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import OutwrightStore
import SwiftUI

/// Search over the header: the field with Cancel, the chips, then either frequent people and
/// recent searches, or the results.
struct SearchView: View {
    let app: AppModel
    @Bindable var model: SearchModel
    @FocusState private var isFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 48
    @State var opening: ShownAttachment?

    /// `model`: the app's open search (`AppModel.search`), which outlives this view when a resize
    /// moves search between the cover and the columns.
    init(app: AppModel, model: SearchModel) {
        self.app = app
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty && model.token == nil {
                beforeTyping
            } else {
                if model.token != nil { direction }
                if model.showsFilterRow { SearchFilterRow(model: model) }
                results
            }
        }
        .background(Theme.background)
        .onAppear { isFieldFocused = model.query.isEmpty }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                field
                    .layoutPriority(1)
                Button {
                    app.isSearching = false
                } label: {
                    Text(ui: "Cancel")
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                // A bar's button: past the largest standard size it would take the field's room.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.offeredChips, id: \.self) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: Icons.search)
                .foregroundStyle(Theme.headerText.opacity(0.7))
            if let token = model.token {
                SearchToken(person: token) { model.removeToken() }
            }
            TextField(text: $model.query) {
                Text(ui: "Mail, people, files").foregroundStyle(Theme.headerText.opacity(0.5))
            }
            .foregroundStyle(Theme.headerText)
            .tint(Theme.accent)
            .focused($isFieldFocused)
            .submitLabel(.search)
            .plainEntry()
            .onSubmit { Task { await model.submit() } }
            .accessibilityIdentifier("search.field")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: Icons.clear)
                        .foregroundStyle(Theme.headerText.opacity(0.5))
                }
                .accessibilityLabel(Text(ui: "Clear"))
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        // Grows with the text, so the clear button keeps beside it rather than over it.
        .frame(minHeight: fieldHeight)
        .background(Theme.headerTrack, in: .capsule)
    }

    private func chipButton(_ chip: SearchChip) -> some View {
        let chosen = model.chip == chip
        return Button {
            model.chip = chip
        } label: {
            Text(ui: Self.title(chip))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(chosen ? Theme.onAccent : Theme.headerText)
                .background(chosen ? Theme.accent : Theme.headerTrack, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    static func title(_ chip: SearchChip) -> LocalizedStringKey {
        switch chip {
        case .all: "All"
        case .mail: "Mail"
        case .people: "People"
        case .events: "Events"
        case .files: "Files"
        }
    }

    /// From or To, over a person's mail.
    private var direction: some View {
        Picker(selection: $model.direction) {
            Text(ui: "From").tag(PersonDirection.from)
            Text(ui: "To").tag(PersonDirection.to)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .accessibilityIdentifier("search.direction")
    }

    // MARK: - Before typing

    private var beforeTyping: some View {
        List {
            if !model.frequentPeople.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(model.frequentPeople, id: \.email) { person in
                            Button {
                                model.query = person.email
                            } label: {
                                PersonBadge(person: person)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("search.person")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            ForEach(model.recentItems) { message in
                Button {
                    open(message)
                } label: {
                    HStack(spacing: 16) {
                        MailIcon()
                        twoLines(AttributedString(Self.subject(message)), byline(message))
                    }
                }
                .accessibilityIdentifier("search.recent")
                .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
            }
            ForEach(model.recentSearches, id: \.self) { recent in
                Button {
                    model.query = recent
                    Task { await model.submit() }
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: Icons.recent)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 40)
                        Text(recent)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 8)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    func byline(_ message: MessageRow) -> Text {
        let sender = message.from.name.flatMap { $0.isEmpty ? nil : $0 } ?? message.from.email
        return Text("\(sender) sent · \(Self.when(message.date))", bundle: .module)
    }

    static func subject(_ message: MessageRow) -> String {
        message.subject.isEmpty ? String(localized: "(No subject)", bundle: .module) : message.subject
    }

    func open(_ message: MessageRow) {
        model.opened(message.id)
        app.openSearchResult(message.id)
    }
}

extension SearchView {
    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return String(localized: "Today", bundle: .module)
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday", bundle: .module)
        }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(date: .abbreviated, time: .omitted)
    }
}
