// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// The meeting card above an invitation message's body: what it is about (invited, updated, cancelled,
/// answered), the meeting's title, time, zone, place and organiser, the owner's calendar around that
/// time, and Accept / Tentative / Decline or Remove from calendar. Tapping the meeting opens its
/// details. Its text is the sender's, shown as plain text.
struct InvitationCard: View {
    let app: AppModel
    /// Set while the card is shown, so the message does not list the calendar part as well.
    @Binding var hidesCalendarPart: Bool
    @State private var model: InvitationCardModel
    @State private var failure: InvitationError?

    init(app: AppModel, message: MessageID, hidesCalendarPart: Binding<Bool>) {
        self.app = app
        _hidesCalendarPart = hidesCalendarPart
        _model = State(initialValue: InvitationCardModel(app: app, message: message))
    }

    var body: some View {
        Group {
            if model.isShown { card }
        }
        .onAppear {
            // The message was read (and taken as an invitation) since the card was made.
            model.reload()
            hidesCalendarPart = model.isShown
        }
        .onChange(of: model.isShown) { _, shown in hidesCalendarPart = shown }
        .task { await model.observe() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Button(action: openDetails) { meeting }
                .buttonStyle(.plain)
                .disabled(model.event == nil)
                .accessibilityHint(Text(ui: "Opens the event"))
                .accessibilityIdentifier("invitation.meeting")
            if let range = model.stripRange(), let meeting = model.meeting {
                MeetingStrip(
                    meeting: meeting, around: model.around, range: range, calendar: model.phone,
                    color: { Color(calendar: model.color(of: $0)) })
            }
            actions
            problems
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.separator.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invitation.card")
    }

    private func openDetails() {
        guard let event = model.event else { return }
        app.eventToShow = EventRequest(event)
    }

    @ViewBuilder private var headline: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.headlineIcon(model.headline))
                .foregroundStyle(Self.headlineColor(model.headline))
                .accessibilityHidden(true)
            headlineText
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.headlineColor(model.headline))
        }
    }

    private var headlineText: Text {
        let organizer = model.organizer
        switch model.headline {
        case .invited:
            return organizer.isEmpty ? Text(ui: "You're invited") : Text(ui: "\(organizer) invited you")
        case .updated(timeMoved: true):
            return Text(ui: "The meeting has a new time")
        case .updated(timeMoved: false):
            return Text(ui: "The meeting was updated")
        case .cancelled:
            return Text(ui: "The meeting was cancelled")
        case let .replied(name, response):
            switch response {
            case .accepted: return Text(ui: "\(name) accepted")
            case .tentative: return Text(ui: "\(name) tentatively accepted")
            case .declined: return Text(ui: "\(name) declined")
            case .needsAction, .delegated: return Text(ui: "\(name) replied")
            }
        case .outdated:
            return Text(ui: "This invitation is out of date. The calendar has a newer version.")
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: model.title.isEmpty ? L10n.string("(No title)") : model.title)
                .font(.headline)
                .strikethrough(model.meeting?.isCancelled == true)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            if !model.timeText.isEmpty {
                line(Icons.time) {
                    Text(verbatim: model.timeText)
                    if let note = model.zoneNote {
                        Text(verbatim: note).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            if !model.place.isEmpty {
                line(Icons.place) { Text(verbatim: model.place).lineLimit(2) }
            }
            if !model.organizer.isEmpty {
                line(Icons.organizer) { Text(verbatim: model.organizer).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func line(_ icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.secondaryText).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2, content: content)
        }
        .font(.subheadline)
    }

    @ViewBuilder private var actions: some View {
        if model.canAnswer {
            RSVPControl(
                response: model.response, occurrence: model.occurrenceScope,
                canWithholdReply: model.canWithholdReply, canComment: model.canComment
            ) { response, sends, scope, comment in
                attempt { () throws(InvitationError) in
                    try model.answer(response, sendReply: sends, scope: scope, comment: comment)
                }
            }
        } else if model.canRemove {
            Button(role: .destructive) {
                attempt { () throws(InvitationError) in try model.removeFromCalendar() }
            } label: {
                Text(ui: "Remove from calendar").frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("invitation.remove")
        }
    }

    @ViewBuilder private var problems: some View {
        if model.replyFailed {
            FailedReplyBanner { attempt { () throws(InvitationError) in try model.retryReply() } }
        }
        if model.replySentByServer {
            Text(ui: "Your calendar server sent a response to the organiser")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("invitation.serverReplied")
        }
        if let failure {
            ProblemBanner(text: Self.message(failure)).clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }

    private func attempt(_ change: () throws(InvitationError) -> Void) {
        do {
            try change()
            failure = nil
        } catch {
            failure = error
        }
    }

    static func message(_ failure: InvitationError) -> String {
        switch failure {
        case .noDraftsFolder: L10n.string("The account has no Drafts folder yet, where the response waits to be sent.")
        case .readOnly: L10n.string("This calendar can't be changed.")
        case .store: L10n.string("The answer couldn't be saved. Try again.")
        }
    }

    static func headlineIcon(_ headline: Headline) -> String {
        switch headline {
        case .invited, .updated: Icons.meeting
        case .cancelled: Icons.eventCancelled
        case let .replied(_, response): Icons.response(response)
        case .outdated: Icons.recent
        }
    }

    static func headlineColor(_ headline: Headline) -> Color {
        switch headline {
        case .cancelled: Theme.delete
        case let .replied(_, response): EventDetailsView.color(response)
        case .invited, .updated, .outdated: Theme.secondaryText
        }
    }
}

/// "Your response was not sent" with Retry: the server took the answer, the reply mail did not leave.
struct FailedReplyBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProblemBanner(text: L10n.string("Your response was not sent"))
            Button(action: retry) { Text(ui: "Retry") }
                .buttonStyle(.bordered)
                .padding(.leading, 8)
                .accessibilityIdentifier("invitation.retry")
        }
    }
}

/// The owner's calendar from an hour before the meeting to an hour after it, on one line of hours: the
/// meeting in its calendar's way (striped while unanswered) and what else is on then, so a clash shows.
struct MeetingStrip: View {
    let meeting: CalendarEvent
    let around: [CalendarEvent]
    let range: ClosedRange<Date>
    let calendar: Calendar
    let color: (CalendarID) -> Color

    private static let laneHeight: CGFloat = 26
    private static let labelHeight: CGFloat = 16
    private static let lanes = 3

    var body: some View {
        let placed = DayLayout.place([meeting] + around) { minutes($0) }
        let lanes = min(max(placed.map(\.columns).max() ?? 1, 1), Self.lanes)
        let total = CGFloat(max(minutes(range.upperBound), 1))
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(hours, id: \.self) { hour in
                    let left = width * CGFloat(minutes(hour)) / total
                    Text(verbatim: hour.formatted(clock))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                        .offset(x: left + 3)
                    Rectangle().fill(Theme.separator)
                        .frame(width: 1, height: CGFloat(lanes) * Self.laneHeight + Self.labelHeight)
                        .offset(x: left)
                }
                ForEach(placed.filter { $0.column < lanes }) { item in
                    let left = width * CGFloat(item.startMinute) / total
                    let right = width * CGFloat(min(item.endMinute, Int(total))) / total
                    EventBlock(
                        event: item.event, color: color(item.event.calendarID), calendar: calendar, showsPlace: false)
                        .overlay {
                            if item.event.id == meeting.id {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1.5)
                            }
                        }
                        .frame(width: max(right - left - 2, 8), height: Self.laneHeight - 2)
                        .offset(x: left + 1, y: Self.labelHeight + CGFloat(item.column) * Self.laneHeight)
                }
            }
        }
        .frame(height: Self.labelHeight + CGFloat(lanes) * Self.laneHeight)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// Minutes from the strip's start, within it.
    private func minutes(_ date: Date) -> Int {
        let length = range.upperBound.timeIntervalSince(range.lowerBound)
        let seconds = min(max(date.timeIntervalSince(range.lowerBound), 0), length)
        return Int(seconds / 60)
    }

    /// The whole hours in the strip, at most a day of them.
    private var hours: [Date] {
        var result: [Date] = []
        let start = calendar.dateInterval(of: .hour, for: range.lowerBound)
        // The strip's own start when it is on the hour, else the next hour.
        var hour = start?.start == range.lowerBound ? range.lowerBound : start?.end ?? range.lowerBound
        while hour < range.upperBound, result.count < 25 {
            result.append(hour)
            hour = hour.addingTimeInterval(3_600)
        }
        return result
    }

    private var clock: Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar,
            timeZone: calendar.timeZone)
    }

    /// The events at the same time, for VoiceOver.
    private var spoken: String {
        let locale = calendar.locale ?? .current
        guard !around.isEmpty else { return L10n.string("Nothing else in your calendar then", locale: locale) }
        return L10n.string("Also in your calendar:", locale: locale) + " "
            + around.prefix(10).map { EventText.spoken($0, in: calendar) }.joined(separator: "; ")
    }
}
