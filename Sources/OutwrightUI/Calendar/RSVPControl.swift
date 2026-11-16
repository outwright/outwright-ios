// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// Accept, Tentative and Decline for an invitation, the owner's current answer marked. One dialog
/// then asks what is still open: for one occurrence of a series whether the answer is for that event
/// or the whole series, and where the app sends the reply itself whether to send it. (One dialog, not
/// two in a row: iOS can drop a second one presented while the first is going.)
struct RSVPControl: View {
    /// The owner's answer now; nil or NEEDS-ACTION when there is none.
    let response: Attendee.Response?
    /// The occurrence the answer may be for alone; nil answers the whole event at once.
    let occurrence: EditScope?
    let canWithholdReply: Bool
    let answer: (Attendee.Response, _ sendReply: Bool, EditScope) -> Void

    /// The answer tapped, waiting for the dialog.
    @State private var asked: Attendee.Response?

    static let answers: [Attendee.Response] = [.accepted, .tentative, .declined]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.answers, id: \.self) { choice in
                button(choice)
            }
        }
        .confirmationDialog(title, isPresented: isAsking, titleVisibility: .visible, presenting: asked) { choice in
            ForEach(Array(choices.enumerated()), id: \.offset) { _, option in
                Button { answer(choice, option.sends, option.scope) } label: { Text(ui: option.label) }
                    .accessibilityIdentifier("rsvp.\(option.identifier)")
            }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: { _ in
            if occurrence != nil { Text(ui: "This event repeats. What is your answer for?") }
        }
    }

    private var title: Text {
        occurrence != nil ? Text(ui: "Answer a repeating event") : Text(ui: "Send a response to the organiser?")
    }

    /// One button of the dialog: what it says, and the scope and sending it answers with.
    private struct Choice {
        let label: LocalizedStringKey
        let identifier: String
        let scope: EditScope
        let sends: Bool
    }

    /// The dialog's buttons: every open question's answers, combined.
    private var choices: [Choice] {
        switch (occurrence, canWithholdReply) {
        case let (occurrence?, true):
            [Choice(
                label: "This event, send the response", identifier: "occurrence.send", scope: occurrence,
                sends: true),
             Choice(
                label: "This event, don't send a response", identifier: "occurrence.dontSend", scope: occurrence,
                sends: false),
             Choice(label: "All events, send the response", identifier: "series.send", scope: .event, sends: true),
             Choice(
                label: "All events, don't send a response", identifier: "series.dontSend", scope: .event,
                sends: false)]
        case let (occurrence?, false):
            [Choice(label: "This event", identifier: "occurrence", scope: occurrence, sends: true),
             Choice(label: "All events in the series", identifier: "series", scope: .event, sends: true)]
        case (nil, _):
            [Choice(label: "Send the response now", identifier: "send", scope: .event, sends: true),
             Choice(label: "Don't send a response", identifier: "dontSend", scope: .event, sends: false)]
        }
    }

    private func button(_ choice: Attendee.Response) -> some View {
        let isCurrent = response == choice
        return Button {
            // Nothing to ask: the whole event, and the server answers the organiser.
            if occurrence == nil && !canWithholdReply { answer(choice, true, .event) } else { asked = choice }
        } label: {
            Label {
                if let label = Self.label(choice, current: isCurrent) {
                    Text(ui: label).lineLimit(1).minimumScaleFactor(0.8)
                }
            } icon: {
                Image(systemName: Self.icon(choice))
            }
            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? EventDetailsView.color(choice) : Theme.secondaryText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("rsvp.\(Self.identifier(choice))")
    }

    private var isAsking: Binding<Bool> {
        Binding { asked != nil } set: { if !$0 { asked = nil } }
    }

    /// The button's word: the answer given ("Accepted") once it is the owner's, else the verb.
    /// None for a response no button gives (an empty key would land in the string catalog).
    static func label(_ choice: Attendee.Response, current: Bool) -> LocalizedStringKey? {
        switch (choice, current) {
        case (.accepted, false): "Accept"
        case (.accepted, true): "Accepted"
        case (.tentative, _): "Tentative"
        case (.declined, false): "Decline"
        case (.declined, true): "Declined"
        case (.needsAction, _), (.delegated, _): nil
        }
    }

    static func icon(_ choice: Attendee.Response) -> String {
        switch choice {
        case .accepted: "checkmark"
        case .tentative: "questionmark"
        case .declined: "xmark"
        case .needsAction, .delegated: "circle"
        }
    }

    private static func identifier(_ choice: Attendee.Response) -> String {
        switch choice {
        case .accepted: "accept"
        case .tentative: "tentative"
        case .declined: "decline"
        case .needsAction, .delegated: "other"
        }
    }
}
