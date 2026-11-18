// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightIMAP
import Testing
@testable import OutwrightSync

/// Which calendar parts a message's structure names make it an invitation before its body is read.
@Suite struct RowBuilderInvitationTests {
    @Test func aCalendarPartThatInvitesOrNamesNoMethodMakesAnInvitation() {
        #expect(RowBuilder.mayBeInvitation([CalendarPartOutline(method: "REQUEST")]))
        #expect(RowBuilder.mayBeInvitation([CalendarPartOutline(method: " cancel ")]))
        #expect(RowBuilder.mayBeInvitation([CalendarPartOutline(method: nil)]))
    }

    @Test func aPublishedCalendarOrNoCalendarPartIsNoInvitation() {
        #expect(!RowBuilder.mayBeInvitation([CalendarPartOutline(method: "PUBLISH")]))
        #expect(!RowBuilder.mayBeInvitation([]))
    }
}
