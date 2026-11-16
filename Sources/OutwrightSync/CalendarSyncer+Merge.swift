// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightDAV
import OutwrightModel

extension CalendarSyncer {
    /// The owner's later edits over the server's copy of a create that landed earlier: the series event
    /// merged field by field (`EventMapping.merged`, `start` being what was first sent), then the edits of
    /// single occurrences in order. Without a series event on either side, or without an edit of the
    /// series event (an invitation's answers and reminder: the owner's own lines, never a field merge,
    /// which would write the organiser's fields and SEQUENCE), the edits are applied as they are.
    func merging(
        _ later: [EventEdit], start: ICalComponent, over server: ICalComponent, uid: String
    ) -> ICalComponent {
        guard later.contains(where: Self.isSeriesEdit) else { return written(later, onto: server, uid: uid) }
        let ours = written(later, onto: start, uid: uid)
        let first = EventMapping.series(start).first
        let mine = EventMapping.series(ours).first
        let theirs = EventMapping.series(server).first
        guard let base = first?.base, let own = mine?.base, let held = theirs?.base else {
            return written(later, onto: server, uid: uid)
        }
        let rule = mine?.rule != first?.rule ? mine?.rule : theirs?.rule
        let details = EventMapping.merged(base: base, ours: own, theirs: held)
        var result = EventMapping.apply(
            .update(details, rule: rule, scope: .event), to: server, uid: uid, organizer: account.email)
        for edit in later where Self.isOccurrenceEdit(edit) {
            result = EventMapping.apply(edit, to: result, uid: uid, organizer: account.email)
        }
        return result
    }

    private static func isSeriesEdit(_ edit: EventEdit) -> Bool {
        if case .update(_, _, .event) = edit { return true }
        return false
    }

    private static func isOccurrenceEdit(_ edit: EventEdit) -> Bool {
        switch edit {
        case .update(_, _, .occurrence), .delete(.occurrence): true
        default: false
        }
    }
}
