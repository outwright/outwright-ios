// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightGraph
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightSync

private func utc(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
}

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

extension GraphHarness {
    /// The held event (its first occurrence in March 2026).
    func heldEvent(_ title: String) throws -> CalendarEvent {
        try #require(try store.occurrences(
            from: graphNow, to: graphNow.addingTimeInterval(60 * 86_400), in: nil
        ).first { $0.occurrence.details.title == title })
    }

    func calendarID() throws -> CalendarID {
        try #require(try store.calendars(account.id).first?.id)
    }

    /// The bodies of the requests sent with `method`, as JSON.
    func bodies(_ method: String) async -> [[String: Any]] {
        await graph.requests.filter { $0.method == method }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
        }
    }

    func lunch() -> Data {
        graphEvent(
            "Lunch", "2026-03-04T11:00:00", "2026-03-04T12:00:00",
            ["body": ["contentType": "html", "content": "<b>At noon</b>"],
             "attendees": [["emailAddress": ["address": "a@example.org"], "type": "required"]]])
    }

    func standup() -> Data {
        graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", graphWeekly)
    }

    /// Someone else's meeting the account is invited to, not yet answered (as the invitee's copy).
    func invitation(_ title: String = "Review", _ more: [String: Any] = [:]) -> Data {
        var fields: [String: Any] = [
            "isOrganizer": false, "iCalUId": "uid-\(title)",
            "organizer": ["emailAddress": ["address": "boss@example.org", "name": "Boss"]],
            "attendees": [
                ["emailAddress": ["address": account.email], "type": "required", "status": ["response": "none"]],
            ],
            "responseStatus": ["response": "notResponded"],
            "isReminderOn": true, "reminderMinutesBeforeStart": 15,
        ]
        for (key, value) in more { fields[key] = value }
        return graphEvent(title, "2026-03-04T13:00:00", "2026-03-04T14:00:00", fields)
    }
}

private func newEvent(_ title: String) -> EventDetails {
    EventDetails(
        title: title,
        start: .zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 10, minute: 0, second: 0), zone: "Europe/Stockholm"),
        end: .zoned(DateComponents(year: 2026, month: 3, day: 5, hour: 11, minute: 0, second: 0), zone: "Europe/Stockholm"),
        reminder: 15)
}

@Suite(.serialized) struct GraphCalendarQueueTests {
    @Test func createReachesGraphAndIsHeld() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            _ = try h.store.createEvent(newEvent("Plan"), rule: nil, in: try h.calendarID())
            try await syncer.sync()
            let made = try #require(await h.graph.allEventsJSON().first)
            #expect(try object(made)["subject"] as? String == "Plan")
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            #expect(try h.heldEvent("Plan").isEditable)
            try await syncer.sync()
            #expect(await h.graph.allEventsJSON().count == 1)
        }
    }

    @Test func aLostCreateIsFoundNotDuplicated() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            _ = try h.store.createEvent(newEvent("Plan"), rule: nil, in: try h.calendarID())
            await h.graph.dropAnswerOfNextPost()
            try? await syncer.sync()
            try await syncer.sync()
            #expect(await h.graph.allEventsJSON().count == 1)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func aSeriesIsCreatedWithItsPattern() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            _ = try h.store.createEvent(newEvent("Weekly"), rule: RecurrenceRule(freq: .weekly, count: 3), in: try h.calendarID())
            try await syncer.sync()
            let made = try object(await h.graph.allEventsJSON().first)
            let range = (made["recurrence"] as? [String: Any])?["range"] as? [String: Any]
            #expect(range?["type"] as? String == "numbered")
            #expect(try h.held().filter { $0.title == "Weekly" }.count == 3)
        }
    }

    @Test func updateOfTitleSendsOnlyTheTitle() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(h.lunch(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try h.heldEvent("Lunch")
            var edited = held.occurrence.details
            edited.title = "Dinner"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            try await syncer.sync()
            let patch = try #require(await h.graph.requests.last { $0.method == "PATCH" })
            #expect(patch.headers["if-match"] == #"W/"ck1""#)
            #expect(Set(try object(patch.body).keys) == ["subject"])
            #expect(try object(await h.graph.eventJSON(lunch))["subject"] as? String == "Dinner")
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func updateConflictKeepsBoth() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(h.lunch(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try h.heldEvent("Lunch")
            var edited = held.occurrence.details
            edited.title = "Mine"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            await h.graph.editEvent(lunch, "subject", "Theirs")
            try await syncer.sync()
            let shown = try h.heldEvent("Theirs")
            #expect(shown.conflict != nil)
            #expect(try object(await h.graph.eventJSON(lunch))["subject"] as? String == "Theirs")
        }
    }

    @Test func updateOfAGoneEventFails() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(h.lunch(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try h.heldEvent("Lunch")
            var edited = held.occurrence.details
            edited.title = "Mine"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            await h.graph.removeEvent(lunch)
            try? await syncer.sync()
            #expect(try h.heldEvent("Mine").changeFailed)
        }
    }

    @Test func deleteReachesGraphAndAGoneOneIsDone() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let lunch = await h.graph.putEvent(h.lunch(), in: home)
            await h.graph.putEvent(graphEvent("Tea", "2026-03-05T15:00:00", "2026-03-05T15:30:00"), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.deleteEvent(try h.heldEvent("Lunch").id, scope: .event)
            try h.store.deleteEvent(try h.heldEvent("Tea").id, scope: .event)
            let tea = try #require(await h.graph.allEventsJSON().compactMap { try? object($0) }
                .first { $0["subject"] as? String == "Tea" }?["id"] as? String)
            await h.graph.removeEvent(tea)
            try await syncer.sync()
            #expect(await h.graph.eventJSON(lunch) == nil)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            #expect(try h.held().isEmpty)
        }
    }

    @Test func thisOccurrenceIsPatchedByItsInstanceID() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(h.standup(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let second = try #require(try h.store.occurrences(
                from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"), in: nil).first)
            let recurrence = try #require(second.occurrence.recurrenceID)
            var edited = second.occurrence.details
            edited.title = "Standup, special"
            try h.store.updateEvent(second.id, edited, rule: nil, scope: .occurrence(recurrence))
            try await syncer.sync()
            let patch = try #require(await h.graph.requests.last { $0.method == "PATCH" })
            #expect(patch.path.hasPrefix("/v1.0/me/events/occ.\(series).2026-03-09"))
            let held = try h.held()
            #expect(held.count == 4 && held.filter { $0.title == "Standup, special" }.count == 1)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func deleteThisOccurrenceDeletesTheInstance() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(h.standup(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let second = try #require(try h.store.occurrences(
                from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"), in: nil).first)
            try h.store.deleteEvent(second.id, scope: .occurrence(try #require(second.occurrence.recurrenceID)))
            try await syncer.sync()
            let master = try object(await h.graph.eventJSON(series))
            #expect((master["cancelledOccurrences"] as? [String]) == ["OID.\(series).2026-03-09"])
            #expect(try h.held().count == 3)
        }
    }

    /// Offline, one occurrence deleted and then the series renamed: both reach Graph, no conflict.
    @Test func anOccurrenceEditThenASeriesEditIsNoConflict() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(h.standup(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let second = try #require(try h.store.occurrences(
                from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"), in: nil).first)
            try h.store.deleteEvent(second.id, scope: .occurrence(try #require(second.occurrence.recurrenceID)))
            let first = try h.heldEvent("Standup")
            var renamed = first.occurrence.details
            renamed.title = "Daily"
            let rule = try h.store.series(first.id)?.rule
            try h.store.updateEvent(first.id, renamed, rule: rule, scope: .event)
            // Exchange gives the series event a new version when one of its occurrences changes.
            await h.graph.editEvent(series, "importance", "normal")
            try await syncer.sync()
            #expect(try object(await h.graph.eventJSON(series))["subject"] as? String == "Daily")
            #expect(try h.heldEvent("Daily").conflict == nil)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    /// An occurrence already deleted elsewhere: the owner's delete of it is done, not failed.
    @Test func deletingAnOccurrenceAlreadyGoneIsDone() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(h.standup(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let second = try #require(try h.store.occurrences(
                from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"), in: nil).first)
            try h.store.deleteEvent(second.id, scope: .occurrence(try #require(second.occurrence.recurrenceID)))
            await h.graph.cancelOccurrence(of: series, on: "2026-03-09")
            try await syncer.sync()
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            #expect(try !h.heldEvent("Standup").changeFailed)
            #expect(try h.held().count == 3)
        }
    }

    /// An all-day series' occurrence is found by its date, wherever the phone is.
    @Test func anAllDayOccurrenceIsFoundFromAnotherZone() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let series = await h.graph.putEvent(graphEvent(
                "Holiday", "2026-03-02T00:00:00", "2026-03-03T00:00:00", graphWeekly.merging(["isAllDay": true]) { $1 }
            ), in: home)
            let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
            let syncer = GraphCalendarSyncer(
                account: h.account, store: h.store, credentials: h.microsoft.credentials, lock: AccountLock(),
                base: h.base, session: URLSession(configuration: .ephemeral), now: { graphNow },
                phoneZone: { losAngeles })
            try await syncer.sync()
            let held = try h.store.occurrences(
                from: graphNow.addingTimeInterval(-30 * 86_400), to: graphNow.addingTimeInterval(60 * 86_400), in: nil)
            let second = try #require(held.first { $0.occurrence.recurrenceID == .date(year: 2026, month: 3, day: 9) })
            try h.store.deleteEvent(second.id, scope: .occurrence(try #require(second.occurrence.recurrenceID)))
            try await syncer.sync()
            let master = try object(await h.graph.eventJSON(series))
            #expect((master["cancelledOccurrences"] as? [String]) == ["OID.\(series).2026-03-09"])
        }
    }

    @Test func aRefusalForGoodFails() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(h.lunch(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try h.heldEvent("Lunch")
            var edited = held.occurrence.details
            edited.title = "Mine"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            await h.graph.failNext(status: 400)
            try? await syncer.sync()
            #expect(try h.heldEvent("Mine").changeFailed)
        }
    }

    @Test func serverTroubleCountsAttempts() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(h.lunch(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let held = try h.heldEvent("Lunch")
            var edited = held.occurrence.details
            edited.title = "Mine"
            try h.store.updateEvent(held.id, edited, rule: nil, scope: .event)
            for _ in 0..<CalendarSyncer.serverAttempts {
                await h.graph.failNext(status: 500)
                try? await syncer.runChanges()
            }
            #expect(try h.heldEvent("Mine").changeFailed)
        }
    }

    @Test func aDeleteOfAnUnsentCreateIsDroppedWithoutARequest() async throws {
        try await withGraphContacts { h in
            await h.graph.addCalendar("Calendar")
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let id = try h.store.createEvent(newEvent("Never"), rule: nil, in: try h.calendarID())
            try h.store.deleteEvent(id, scope: .event)
            let before = await h.graph.requests.count
            try await syncer.runChanges()
            #expect(await h.graph.requests.count == before)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }
    @Test func anAnswerGoesToGraphWhichAnswersTheOrganiser() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let review = await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.respond(try h.heldEvent("Review").id, .accepted, scope: .event, sendReply: true)
            try await syncer.sync()
            let post = try #require(await h.graph.requests.last { $0.method == "POST" })
            #expect(post.path.hasPrefix("/v1.0/me/events/\(review)/accept"))
            #expect(try object(post.body)["sendResponse"] as? Bool == true)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            let own = try h.heldEvent("Review").occurrence.details.attendees.first { $0.email == h.account.email }
            #expect(own?.response == .accepted)
            // Graph answers the organiser itself: the app writes no reply of its own.
            #expect(try h.store.pendingActions().isEmpty)
        }
    }

    @Test func anAnswersCommentGoesToGraph() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            _ = await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.respond(
                try h.heldEvent("Review").id, .tentative, scope: .event, sendReply: true, comment: "Maybe\nlate")
            try await syncer.sync()
            let post = try #require(await h.graph.requests.last { $0.method == "POST" })
            let comment = try #require(try object(post.body)["comment"] as? String)
            #expect(comment.contains("Maybe") && comment.contains("late") && !comment.contains("\n"))
        }
    }

    @Test func aDeclineWithoutAReplyTellsGraphNotToSendOne() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let review = await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let id = try h.heldEvent("Review").id
            try h.store.respond(id, .declined, scope: .event, sendReply: false)
            try await syncer.sync()
            let post = try #require(await h.graph.requests.last { $0.method == "POST" })
            #expect(post.path.hasPrefix("/v1.0/me/events/\(review)/decline"))
            #expect(try object(post.body)["sendResponse"] as? Bool == false)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            // Graph took the declined meeting out of the calendar: it goes here too, not as a failure.
            try await syncer.sync()
            #expect(try h.store.series(id) == nil)
        }
    }

    @Test func anOccurrenceIsAnsweredByItsInstanceID() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            var weekly = graphWeekly
            weekly["isOrganizer"] = false
            weekly["organizer"] = ["emailAddress": ["address": "boss@example.org"]]
            weekly["attendees"] = [["emailAddress": ["address": h.account.email], "type": "required"]]
            let series = await h.graph.putEvent(
                graphEvent("Standup", "2026-03-02T08:00:00", "2026-03-02T08:15:00", weekly), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let second = try #require(try h.store.occurrences(
                from: try utc("2026-03-09T00:00:00Z"), to: try utc("2026-03-10T00:00:00Z"), in: nil).first)
            let recurrence = try #require(second.occurrence.recurrenceID)
            try h.store.respond(second.id, .tentative, scope: .occurrence(recurrence), sendReply: true)
            try await syncer.sync()
            let post = try #require(await h.graph.requests.last { $0.method == "POST" })
            #expect(post.path.hasPrefix("/v1.0/me/events/occ.\(series).2026-03-09/tentativelyAccept"))
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    @Test func theOwnReminderOfAnInvitationIsPatched() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let review = await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.setOwnReminder(try h.heldEvent("Review").id, minutes: 30, scope: .event)
            try await syncer.sync()
            let patch = try #require(await h.graph.requests.last { $0.method == "PATCH" })
            #expect(try object(patch.body)["reminderMinutesBeforeStart"] as? Int == 30)
            #expect(try object(patch.body)["isReminderOn"] as? Bool == true)
            #expect(try h.heldEvent("Review").occurrence.details.reminder == 30)
            try h.store.setOwnReminder(try h.heldEvent("Review").id, minutes: nil, scope: .event)
            try await syncer.sync()
            #expect(try object(await h.graph.eventJSON(review))["isReminderOn"] as? Bool == false)
            #expect(try h.heldEvent("Review").occurrence.details.reminder == nil)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
        }
    }

    /// The meeting gone before the decline reached Graph (its organiser called it off, or an earlier
    /// try's answer was lost after Graph had moved it away): the decline is done, not failed.
    @Test func aDeclineOfAMeetingAlreadyGoneIsDone() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            let review = await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            let id = try h.heldEvent("Review").id
            try h.store.respond(id, .declined, scope: .event, sendReply: true)
            await h.graph.removeEvent(review)
            try await syncer.sync()
            #expect(try h.store.series(id) == nil)
        }
    }

    /// An answer Graph has no action for (delegated) is not dropped without a word: it fails, and
    /// nothing is sent.
    @Test func anAnswerGraphCannotSendFails() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(h.invitation(), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.respond(try h.heldEvent("Review").id, .delegated, scope: .event, sendReply: true)
            try? await syncer.sync()
            #expect(await h.graph.requests.allSatisfy { $0.method != "POST" })
            #expect(try h.heldEvent("Review").changeFailed)
        }
    }

    /// The organiser asked for no response: the answer is given without one, as Graph requires.
    @Test func anAnswerToAMeetingThatWantsNoResponseSendsNone() async throws {
        try await withGraphContacts { h in
            let home = await h.graph.addCalendar("Calendar")
            await h.graph.putEvent(h.invitation("Review", ["responseRequested": false]), in: home)
            let syncer = h.calendarSyncer()
            try await syncer.sync()
            try h.store.respond(try h.heldEvent("Review").id, .accepted, scope: .event, sendReply: true)
            try await syncer.sync()
            let post = try #require(await h.graph.requests.last { $0.method == "POST" })
            #expect(try object(post.body)["sendResponse"] as? Bool == false)
            #expect(try h.store.pendingEventChanges(h.account.id).isEmpty)
            #expect(try !h.heldEvent("Review").changeFailed)
        }
    }
}

