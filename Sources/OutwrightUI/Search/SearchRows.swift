// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import SwiftUI

/// A person in the results: avatar, name (matches in bold), address or phone, and the card button.
struct SearchPersonRow: View {
    @ScaledMetric(relativeTo: .title3) private var cardButton: CGFloat = 44
    let person: SearchPerson
    let query: String
    let choose: () -> Void
    let openCard: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: choose) {
                HStack(spacing: 16) {
                    Avatar(name: person.name, email: person.emails.first ?? person.name, size: 44)
                    SearchTwoLines(
                        first: SearchModel.highlighted(person.name, query: query),
                        second: person.detail.isEmpty ? nil : Text(verbatim: person.detail))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.result")
            Button(action: openCard) {
                Image(systemName: Icons.personCard)
                    .font(.title3)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: cardButton, height: cardButton)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "Contact card"))
            .accessibilityIdentifier("search.cardButton")
        }
    }
}

/// An event in the results: calendar mark, title (matches in bold), day and time.
struct SearchEventRow: View {
    @ScaledMetric(relativeTo: .title3) private var badge: CGFloat = 44
    let event: CalendarEvent
    let query: String

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Theme.accent)
                .frame(width: badge, height: badge)
                .overlay { Image(systemName: Icons.calendar).foregroundStyle(Theme.onAccent) }
                .accessibilityHidden(true)
            SearchTwoLines(
                first: SearchModel.highlighted(event.occurrence.details.title, query: query),
                second: Text(verbatim: Self.when(event.occurrence, now: Date(), in: .autoupdatingCurrent)))
        }
    }

    /// "Today · 09:00 – 11:30": the day as a word near today, else a weekday or a date; the hours, or
    /// all day.
    static func when(_ occurrence: Occurrence, now: Date, in phone: Calendar) -> String {
        let locale = phone.locale ?? .current
        let start = occurrence.allDayStart.flatMap { EventText.day($0, phone) } ?? occurrence.start
        let day: String
        if phone.isDateInToday(start) {
            day = L10n.string("Today", locale: locale)
        } else if phone.isDateInTomorrow(start) {
            day = L10n.string("Tomorrow", locale: locale)
        } else if phone.isDateInYesterday(start) {
            day = L10n.string("Yesterday", locale: locale)
        } else if start > now, start < now.addingTimeInterval(6 * 86_400) {
            let weekday = Date.FormatStyle(locale: locale, calendar: phone, timeZone: phone.timeZone).weekday(.wide)
            day = start.formatted(weekday)
        } else {
            let sameYear = phone.component(.year, from: start) == phone.component(.year, from: now)
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: phone,
                                         timeZone: phone.timeZone).day().month(.abbreviated)
            if !sameYear { style = style.year() }
            day = start.formatted(style)
        }
        guard occurrence.allDayStart == nil else { return day + " · " + L10n.string("All day", locale: locale) }
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: phone,
                                     timeZone: phone.timeZone)
        let end = max(occurrence.end, occurrence.start)
        return day + " · " + occurrence.start.formatted(clock) + " – " + end.formatted(clock)
    }
}

/// A completion of what was typed: a magnifier and the words, the typed part in bold.
struct SearchSuggestionRow: View {
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 40
    let text: String
    let query: String

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: Icons.search)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: iconWidth)
            Text(SearchModel.highlighted(text, query: query))
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
    }
}

/// The two lines of a result: the first large with its matches in bold, the second quieter (left
/// out when there is nothing to say on it).
struct SearchTwoLines: View {
    let first: AttributedString
    let second: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(first)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let second {
                second
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The person whose mail is shown, in the search field: initials and name, and ✕ to go back.
struct SearchToken: View {
    let person: SearchPerson
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Avatar(name: person.name, email: person.emails.first ?? person.name, size: 24)
            Text(verbatim: person.name)
                .lineLimit(1)
                .foregroundStyle(Theme.headerText)
            Button(action: remove) {
                Image(systemName: Icons.close)
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.headerText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ui: "Remove person"))
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Theme.accentSoft, in: Capsule())
        .accessibilityIdentifier("search.token")
    }
}
