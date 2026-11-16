// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// The event editor sheet: ✕, the calendar with its account, ✓; then the title with the calendar's
/// colour, People, All day, the start and end with the length, the time zone, the place, the
/// reminder, the repeat and the notes.
struct EventEditorView: View {
    let app: AppModel
    @State private var model: EventEditorModel
    @State private var failure: EventEditError?
    @State private var asksToDiscard = false
    @State private var warnsOverrides = false
    @State private var typing = ""
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    enum Field: Hashable { case title, people }

    static let reminders: [Int?] = [nil, 0, 5, 15, 30, 60, 120, 1_440, 2_880, 10_080]

    init(app: AppModel, request: EventEditorRequest) {
        self.app = app
        _model = State(
            initialValue: EventEditorModel(app: app, editing: request.editing, day: request.day, scope: request.scope))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure { ProblemBanner(text: Self.message(failure)) }
                if model.isOverLimits {
                    ProblemBanner(text: L10n.string("This calendar can't hold this repeat. Choose one from the list."))
                }
                titleSection
                timeSection
                detailsSection
                Section {
                    TextField(text: $model.details.notes, axis: .vertical) { Text(ui: "Notes") }
                        .lineLimit(4...12)
                        .accessibilityIdentifier("editor.notes")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        // Swiping the sheet away would lose what is typed without asking.
        .interactiveDismissDisabled(model.hasChanges)
        .confirmationDialog(Text(ui: "Discard your changes?"), isPresented: $asksToDiscard, titleVisibility: .visible) {
            Button(role: .destructive) { dismiss() } label: { Text(ui: "Discard changes") }
            Button(role: .cancel) {} label: { Text(ui: "Keep editing") }
        }
        .confirmationDialog(
            Text(ui: "Save the change to the whole series?"), isPresented: $warnsOverrides, titleVisibility: .visible
        ) {
            Button(role: .destructive) { save() } label: { Text(ui: "Save the series") }
                .accessibilityIdentifier("editor.saveSeries")
            Button(role: .cancel) {} label: { Text(ui: "Keep editing") }
        } message: {
            Text(
                ui: """
                    A new time or repeat for the series removes what was changed or deleted in single events \
                    of it.
                    """)
        }
        .onAppear { if model.isNew { focus = .title } }
    }

    // MARK: - Header

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { if model.hasChanges { asksToDiscard = true } else { dismiss() } } label: {
                Image(systemName: Icons.close)
            }
            .accessibilityLabel(Text(ui: "Close"))
            .accessibilityIdentifier("editor.close")
        }
        ToolbarItem(placement: .principal) { calendarPicker }
        ToolbarItem(placement: .confirmationAction) {
            Button { attemptSave() } label: { Image(systemName: "checkmark") }
                .disabled(!model.canSave)
                .accessibilityLabel(Text(ui: "Save"))
                .accessibilityIdentifier("editor.save")
        }
    }

    /// The calendar the event goes to; a menu of the writable ones for a new event.
    @ViewBuilder private var calendarPicker: some View {
        if let chosen = model.chosen {
            if model.isNew && model.writableCalendars.flatMap(\.calendars).count > 1 {
                Menu {
                    ForEach(model.writableCalendars, id: \.account.id) { group in
                        Section(group.account.displayName) {
                            ForEach(group.calendars) { cal in
                                Button { model.calendar = cal.id } label: {
                                    if cal.id == model.calendar {
                                        Label(cal.name, systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: cal.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    calendarLabel(chosen.account, chosen.calendar, chevron: true)
                }
                .accessibilityLabel(Text(ui: "Calendar"))
                .accessibilityIdentifier("editor.calendar")
            } else {
                calendarLabel(chosen.account, chosen.calendar, chevron: false)
            }
        }
    }

    private func calendarLabel(_ account: Account, _ cal: CalendarInfo, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            Avatar(name: account.displayName, email: account.email, size: 24, colorIndex: account.colorIndex)
            Text(verbatim: cal.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
            if chevron { Image(systemName: "chevron.down").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    // MARK: - Fields

    private var titleSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(calendar: model.chosen?.calendar.color ?? 0x8A8F98))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                TextField(text: $model.details.title) { Text(ui: "Title") }
                    .font(.title3)
                    .focused($focus, equals: .title)
                    .accessibilityIdentifier("editor.title")
            }
            RecipientField(
                label: "People", addresses: $model.people, typing: $typing, focus: $focus, field: .people,
                identifierPrefix: "editor")
                .padding(.leading, -20)
            ForEach(suggestions, id: \.email) { person in
                Button {
                    model.people.append(person)
                    typing = ""
                } label: {
                    HStack(spacing: 12) {
                        Avatar(name: person.name, email: person.email, size: 30)
                        Text(verbatim: person.name ?? person.email).foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var suggestions: [Address] {
        guard focus == .people else { return [] }
        return model.suggestions(for: typing)
    }

    private var timeSection: some View {
        Section {
            Toggle(isOn: $model.isAllDay) { ModuleLabel("All day", systemImage: Icons.calendar) }
                .accessibilityIdentifier("editor.allDay")
            Group {
                DatePicker(selection: $model.start, displayedComponents: components) { Text(ui: "Starts") }
                    .accessibilityIdentifier("editor.start")
                DatePicker(selection: $model.end, displayedComponents: components) { Text(ui: "Ends") }
                    .accessibilityIdentifier("editor.end")
            }
            .environment(\.timeZone, model.pickerZone)
            LabeledContent {
                Text(verbatim: model.durationText)
            } label: {
                Text(ui: "Length")
            }
            if !model.isAllDay {
                NavigationLink {
                    ZonePicker(zone: $model.zone)
                } label: {
                    LabeledContent {
                        Text(verbatim: Self.zoneName(model.zone))
                    } label: {
                        ModuleLabel("Time zone", systemImage: "globe")
                    }
                }
                .accessibilityIdentifier("editor.zone")
            }
        } footer: {
            if model.endsBeforeStart { Text(ui: "The event ends before it starts.").foregroundStyle(Theme.delete) }
        }
    }

    private var components: DatePickerComponents {
        model.isAllDay ? [.date] : [.date, .hourAndMinute]
    }

    private var detailsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: Icons.place).foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
                TextField(text: $model.details.place) { Text(ui: "Place") }
                    .accessibilityIdentifier("editor.place")
            }
            Picker(selection: $model.details.reminder) {
                ForEach(reminderChoices, id: \.self) { minutes in
                    Text(verbatim: reminderText(minutes)).tag(minutes)
                }
            } label: {
                ModuleLabel("Reminder", systemImage: Icons.reminder)
            }
            .accessibilityIdentifier("editor.reminder")
            if model.editsRule {
                RepeatPicker(choice: $model.repeatChoice, showsCustom: model.hasCustomRule)
            }
        }
    }

    private var reminderChoices: [Int?] {
        let current = model.details.reminder
        return Self.reminders.contains(current) ? Self.reminders : Self.reminders + [current]
    }

    private func reminderText(_ minutes: Int?) -> String {
        guard let minutes else { return L10n.string("None") }
        return EventText.reminder(minutes, locale: model.phone.locale ?? .current)
    }

    static func zoneName(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
    }

    // MARK: - Saving

    private func attemptSave() {
        // An address still being typed is one of the people.
        let (found, _) = RecipientParser.split(typing)
        if !found.isEmpty {
            model.people += found
            typing = ""
        }
        if model.dropsOverrides { warnsOverrides = true } else { save() }
    }

    private func save() {
        do {
            _ = try model.save(scope: model.scope)
            dismiss()
        } catch {
            failure = error
        }
    }

    static func message(_ error: EventEditError) -> String {
        switch error {
        case .noCalendar: L10n.string("There is no calendar to put the event in.")
        case .endBeforeStart: L10n.string("The event ends before it starts.")
        case .store: L10n.string("The event couldn't be saved. Try again.")
        }
    }
}

/// The time zones, searchable; choosing one goes back.
struct ZonePicker: View {
    @Binding var zone: TimeZone
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private static let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        List(shown, id: \.self) { identifier in
            Button {
                if let picked = TimeZone(identifier: identifier) { zone = picked }
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: identifier.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                        if let name = TimeZone(identifier: identifier).map(EventEditorView.zoneName) {
                            Text(verbatim: name).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if identifier == zone.identifier { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(Text(ui: "Time zone"))
    }

    private var shown: [String] {
        let wanted = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return Self.identifiers }
        return Self.identifiers.filter { identifier in
            identifier.lowercased().replacingOccurrences(of: "_", with: " ").contains(wanted)
                || (TimeZone(identifier: identifier).map(EventEditorView.zoneName)?.lowercased().contains(wanted)
                    ?? false)
        }
    }
}
