// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// An event's details, under a band in its calendar's colour with Join for a meeting. Its text is
/// shown as plain text only; a link in the place or the notes, and the place in Maps, are buttons that
/// open outside the app when the owner taps them, and nothing in the event is fetched. The organiser
/// and the people open their cards, and Email attendees writes to them all.
struct EventDetailsView: View {
    let app: AppModel
    @State private var model: EventDetailsModel
    @State private var seriesAction: SeriesAction?
    @State private var confirmsDelete = false
    @State private var actionFailed = false
    @State private var invitationFailure: InvitationError?
    @State private var confirmsDecline = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(app: AppModel, request: EventRequest) {
        self.app = app
        _model = State(initialValue: EventDetailsModel(app: app, request: request))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let details = model.details {
                    ScrollView {
                        VStack(spacing: 0) {
                            heading(details)
                            content(details).padding(16)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        ModuleLabel("Event not found", systemImage: Icons.calendar)
                    } description: {
                        Text(ui: "It is no longer in the calendar.")
                    }
                }
            }
            .background(Theme.background)
            .task { await model.observe() }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .seriesScopeDialog($seriesAction, occurrence: model.occurrenceScope) { action, scope in
            switch action {
            case .edit: edit(scope)
            case .delete: delete(scope)
            }
        }
        .confirmationDialog(
            Text(ui: "Delete this invitation?"), isPresented: $confirmsDecline, titleVisibility: .visible
        ) {
            if let occurrence = model.occurrenceScope {
                Button(role: .destructive) { decline(occurrence) } label: { Text(ui: "Decline this event") }
                    .accessibilityIdentifier("event.declineOccurrence")
                Button(role: .destructive) { decline(.event) } label: {
                    Text(ui: "Decline all events in the series")
                }
                .accessibilityIdentifier("event.confirmDecline")
            } else {
                Button(role: .destructive) { decline(.event) } label: { Text(ui: "Delete and decline") }
                    .accessibilityIdentifier("event.confirmDecline")
            }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: {
            Text(ui: "The meeting is declined, and the organiser is told.")
        }
        .confirmationDialog(Text(ui: "Delete this event?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(role: .destructive) { delete(.event) } label: { Text(ui: "Delete event") }
                .accessibilityIdentifier("event.confirmDelete")
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: {
            Text(ui: "The event is deleted from its calendar.")
        }
    }

    /// Opens the editor once these details have closed: this occurrence, or the event (the series).
    private func edit(_ scope: EditScope) {
        guard let event = model.event else { return }
        app.edit(EventRequest(event: event.id, occurrence: event.occurrence.recurrenceID), scope: scope)
    }

    private func delete(_ scope: EditScope) {
        attempt {
            try model.delete(scope: scope)
            dismiss()
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            actionFailed = false
        } catch {
            actionFailed = true
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: Icons.close) }
                .accessibilityLabel(Text(ui: "Close"))
                .accessibilityIdentifier("event.close")
        }
        if model.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.isSeries { seriesAction = .edit } else { edit(.event) }
                } label: {
                    Text(ui: "Edit")
                }
                .accessibilityIdentifier("event.edit")
            }
        }
    }

    private func content(_ details: EventDetails) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            banners
            if model.conflict != nil { conflictBanner }
            if model.canAnswer { rsvp }
            row(Icons.time) {
                Text(verbatim: model.timeText)
                if let note = model.zoneNote {
                    Text(verbatim: note).font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
            }
            if !details.place.isEmpty { place(details.place) }
            if !model.otherLinks.isEmpty { links }
            if let organizer = model.organizer, let address = model.organizerAddress {
                row(Icons.organizer) {
                    Text(ui: "Organiser").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    personButton(address) { Text(verbatim: organizer) }
                }
            }
            if !model.attendees.isEmpty { attendees }
            row(Icons.reminder) {
                if model.canEditReminder { reminderPicker(details) } else { Text(verbatim: model.reminderText) }
            }
            if let repeats = model.repeatText {
                row(Icons.repeats) { Text(verbatim: repeats) }
            }
            if !details.notes.isEmpty {
                row(Icons.notes) {
                    Text(verbatim: String(details.notes.prefix(20_000))).textSelection(.enabled)
                }
            }
            deleteButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The store could not be read, an action failed, or the server refused the last change.
    @ViewBuilder private var banners: some View {
        if model.failed {
            ProblemBanner(text: L10n.string("The calendar couldn't be read. Try again."))
        }
        if actionFailed {
            ProblemBanner(text: L10n.string("The event couldn't be saved. Try again."))
        }
        if let invitationFailure {
            ProblemBanner(text: InvitationCard.message(invitationFailure))
        }
        if model.replyFailed {
            FailedReplyBanner { answering { () throws(InvitationError) in try model.retryReply() } }
        } else if model.changeFailed && model.conflict == nil {
            // The change the server did not take, and giving it up for the server's version.
            HStack(spacing: 0) {
                ProblemBanner(text: L10n.string("Could not be saved"))
                Button(role: .destructive) { attempt { try model.discardFailedChange() } } label: {
                    Text(ui: "Discard")
                }
                .buttonStyle(.bordered)
                .padding(.leading, 8)
                .accessibilityIdentifier("event.discardFailed")
            }
        }
    }

    /// Names every change the conflict holds, since Apply again sends them all.
    private var conflictBanner: some View {
        let count = model.conflictChanges
        return ConflictBanner(
            title: count > 1 ? "Your \(count) changes were not saved" : "Your change was not saved",
            message: count > 1 ? Self.conflictsMessage : Self.conflictMessage,
            primary: ("Apply again", { attempt { try model.applyAgain() } }),
            secondary: ("Discard", { attempt { try model.discard() } }))
    }

    /// The band at the top, in the calendar's colour: the title, the calendar and its account, the
    /// event's state and Join for a meeting.
    private func heading(_ details: EventDetails) -> some View {
        let color = Color(calendar: model.calendar?.color ?? 0x8A8F98)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: details.title.isEmpty ? L10n.string("(No title)") : details.title)
                .font(.title2.bold())
                .strikethrough(details.status == .cancelled)
                .accessibilityIdentifier("event.title")
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(verbatim: [model.calendar?.name, model.account?.displayName].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            if model.event?.isTentative == true {
                Text(ui: "Tentative").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            if details.status == .cancelled {
                Text(ui: "Cancelled").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.delete)
            }
            if details.isPrivate {
                Label { Text(ui: "Private") } icon: { Image(systemName: Icons.privateEvent) }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let meeting = model.meeting { JoinButton(url: meeting, prominent: true) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.16))
    }
}

// MARK: The parts of the details

extension EventDetailsView {
    private func decline(_ scope: EditScope) {
        answering {
            () throws(InvitationError) in
            try model.declineByDeleting(scope: scope)
            dismiss()
        }
    }

    private func answering(_ change: () throws(InvitationError) -> Void) {
        do {
            try change()
            invitationFailure = nil
        } catch {
            invitationFailure = error
        }
    }

    /// Accept, Tentative and Decline, the current answer marked.
    private var rsvp: some View {
        RSVPControl(
            response: model.response, occurrence: model.occurrenceScope, canWithholdReply: model.canWithholdReply,
            canComment: model.canComment
        ) { response, sends, scope, comment in
            answering { () throws(InvitationError) in
                try model.answer(response, sendReply: sends, scope: scope, comment: comment)
            }
        }
    }

    /// Delete for an own event; for an invitation Delete declines it, as Outlook does; a cancelled
    /// meeting is removed from the calendar.
    @ViewBuilder private var deleteButton: some View {
        if model.canEdit {
            Button(role: .destructive) {
                if model.isSeries { seriesAction = .delete } else { confirmsDelete = true }
            } label: {
                Text(ui: "Delete event").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("event.delete")
        } else if model.canDecline {
            // Delete on an invitation declines it, as Outlook does.
            Button(role: .destructive) {
                // One dialog: for a series it also asks which events are declined.
                confirmsDecline = true
            } label: {
                Text(ui: "Delete event").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("event.decline")
        } else if model.canRemoveCancelled {
            Button(role: .destructive) {
                answering { () throws(InvitationError) in
                    try model.removeFromCalendar()
                    dismiss()
                }
            } label: {
                Text(ui: "Remove from calendar").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("event.remove")
        }
    }

    /// The owner's own reminder on an invitation, for the whole event.
    private func reminderPicker(_ details: EventDetails) -> some View {
        let current = details.reminder
        let choices = EventEditorView.reminders.contains(current)
            ? EventEditorView.reminders : EventEditorView.reminders + [current]
        let locale = model.phone.locale ?? .current
        return Picker(selection: Binding(get: { current }, set: { minutes in
            answering { () throws(InvitationError) in try model.setReminder(minutes, scope: .event) }
        })) {
            ForEach(choices, id: \.self) { minutes in
                Text(verbatim: minutes.map { EventText.reminder($0, locale: locale) }
                    ?? L10n.string("None", locale: locale))
                    .tag(minutes)
            }
        } label: {
            Text(ui: "Reminder")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("event.reminder")
    }

    /// The place: a button to Maps, or plain text when it holds a link.
    @ViewBuilder private func place(_ text: String) -> some View {
        row(Icons.place) {
            if let maps = EventLinks.maps(for: text) {
                Button { openURL(maps) } label: {
                    Text(verbatim: text).multilineTextAlignment(.leading).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(ui: "Opens in Maps"))
                .accessibilityIdentifier("event.place")
            } else {
                Text(verbatim: text).textSelection(.enabled)
            }
        }
    }

    /// The links but the meeting's, behind More links: each shows its whole address.
    private var links: some View {
        row(Icons.link) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.otherLinks, id: \.self) { url in
                        Button { openURL(url) } label: {
                            Text(verbatim: url.absoluteString).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(ui: "More links")
            }
            .tint(Theme.secondaryText)
            .accessibilityIdentifier("event.moreLinks")
        }
    }

    private var attendees: some View {
        row(Icons.attendees) {
            Text(ui: "People").font(.subheadline).foregroundStyle(Theme.secondaryText)
            ForEach(Array(model.attendees.enumerated()), id: \.offset) { _, attendee in
                personButton(EventDetailsModel.address(attendee.email, name: attendee.name)) {
                    HStack(spacing: 8) {
                        Image(systemName: Icons.response(attendee.response))
                            .foregroundStyle(Self.color(attendee.response))
                            .accessibilityLabel(Text(ui: Self.response(attendee.response)))
                        Text(verbatim: attendee.name.isEmpty ? attendee.email : attendee.name).lineLimit(1)
                    }
                }
            }
            if !model.emailRecipients.isEmpty {
                Button {
                    app.pendingCompose = ComposeRequest(
                        kind: .people(model.emailRecipients, subject: model.details?.title ?? ""))
                    dismiss()
                } label: {
                    Label { Text(ui: "Email attendees") } icon: { Image(systemName: Icons.emailPeople) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .padding(.top, 4)
                .accessibilityIdentifier("event.emailAttendees")
            }
        }
    }

    /// A person's line: their card opens once the details have closed.
    private func personButton(_ address: Address, @ViewBuilder label: () -> some View) -> some View {
        Button {
            app.pendingPerson = model.person(address)
            dismiss()
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
