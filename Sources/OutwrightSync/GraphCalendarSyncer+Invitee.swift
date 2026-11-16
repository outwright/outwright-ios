// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightGraph
import OutwrightModel

/// The invitee's edits of a Graph event: answers and the own reminder. Graph answers the
/// organiser itself, so no reply mail is written here.
extension GraphCalendarSyncer {
    /// An invitee's edit: an answer through Graph's action for it, or the own reminder. Both are the
    /// invitee's own and go without If-Match, so an organiser's change since does not stop them.
    func applyInvitee(
        _ edit: EventEdit, to target: inout Target, local: EventSeries, _ client: GraphClient
    ) async throws(SyncError) {
        switch edit {
        case let .respond(response, scope, sendReply):
            // No action for it (no answer, delegated): refused, as Graph would a request it can't take.
            guard let answer = Self.answer(response) else { throw .graph(.status(400)) }
            let id = try await place(of: scope, in: target, local: local, client)
            // Graph refuses a response to a meeting whose organiser asked for none.
            let sends = sendReply && target.wantsResponse
            try await graph { () async throws(GraphError) in
                try await client.respond(id: id, answer, sendResponse: sends)
            }
        case let .ownReminder(minutes, scope):
            var body: [String: any Sendable] = ["isReminderOn": minutes != nil]
            if let minutes { body["reminderMinutesBeforeStart"] = minutes }
            let id = try await place(of: scope, in: target, local: local, client)
            _ = try await graph { () async throws(GraphError) in
                try await client.updateEvent(id: id, body, ifMatch: nil)
            }
        case .create, .update, .delete, .guestAnswer, .organiserChange:
            return
        }
        try await refreshETag(&target, client)
    }

    /// The Graph id an edit of `scope` goes to: the event's, or its occurrence's instance.
    func place(
        of scope: EditScope, in target: Target, local: EventSeries, _ client: GraphClient
    ) async throws(SyncError) -> String {
        guard case let .occurrence(time) = scope else { return target.id }
        guard let instance = try await instance(of: target.id, at: time, zones: local.zones, client) else {
            throw .graph(.notFound)
        }
        return instance
    }

    /// Graph's JSON of an event as held here, the account's own answer read for it.
    func mapped(_ data: Data) -> EventSeries? { GraphEventMapping.series(data, ownEmail: account.email) }

    /// Graph's action for an answer; nil for one Graph has no action for (no answer, delegated).
    static func answer(_ response: Attendee.Response) -> GraphAnswer? {
        switch response {
        case .accepted: .accept
        case .tentative: .tentativelyAccept
        case .declined: .decline
        case .needsAction, .delegated: nil
        }
    }
}

extension EventEdit {
    /// A decline, of the whole event or of one occurrence.
    var declines: Bool {
        if case .respond(.declined, _, _) = self { return true }
        return false
    }
}
