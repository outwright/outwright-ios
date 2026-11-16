// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct EventOwnershipTests {
    let me = "me@example.org"

    private func event(organizer: String?, attendees: [Attendee] = [],
                       status: EventStatus = .confirmed) -> EventDetails {
        var details = Cal.hour(Cal.wall(2026, 11, 9, 9), status: status)
        details.organizer = organizer
        details.attendees = attendees
        return details
    }

    private func attendee(_ email: String, _ response: Attendee.Response) -> Attendee {
        Attendee(email: email, name: "", response: response)
    }

    @Test func ownershipFollowsOrganizer() {
        #expect(EventOwnership.isOrganizer(event(organizer: nil), accountEmail: me))
        #expect(EventOwnership.isOrganizer(event(organizer: "Me@Example.org"), accountEmail: me))
        #expect(!EventOwnership.isOrganizer(event(organizer: "boss@example.org"), accountEmail: me))
    }

    @Test func ownAttendeeIsFoundIgnoringCase() {
        let details = event(organizer: "boss@example.org", attendees: [
            attendee("colleague@example.org", .accepted), attendee("ME@EXAMPLE.ORG", .declined),
        ])
        #expect(EventOwnership.ownAttendee(details, accountEmail: me)?.response == .declined)
        #expect(EventOwnership.ownAttendee(event(organizer: nil), accountEmail: me) == nil)
    }

    @Test func tentativeFromStatusOrOwnResponse() {
        #expect(EventOwnership.isTentative(event(organizer: nil, status: .tentative), accountEmail: me))
        let mine = event(organizer: "boss@example.org", attendees: [attendee("me@example.org", .tentative)])
        #expect(EventOwnership.isTentative(mine, accountEmail: me))
        let theirs = event(organizer: "boss@example.org", attendees: [
            attendee("other@example.org", .tentative), attendee("me@example.org", .accepted),
        ])
        #expect(!EventOwnership.isTentative(theirs, accountEmail: me))
    }

    @Test func unansweredInvitationDrawsTentative() {
        let invited = event(organizer: "boss@example.org", attendees: [attendee("me@example.org", .needsAction)])
        #expect(EventOwnership.isTentative(invited, accountEmail: me))
        let answered = event(organizer: "boss@example.org", attendees: [attendee("me@example.org", .accepted)])
        #expect(!EventOwnership.isTentative(answered, accountEmail: me))
    }

    @Test func ownEventWithoutAttendeesIsNotTentative() {
        #expect(!EventOwnership.isTentative(event(organizer: nil), accountEmail: me))
        #expect(!EventOwnership.isTentative(event(organizer: me), accountEmail: me))
        // The organiser's own line awaiting an answer is not an invitation to the organiser.
        let own = event(organizer: me, attendees: [attendee("me@example.org", .needsAction)])
        #expect(!EventOwnership.isTentative(own, accountEmail: me))
    }
}
