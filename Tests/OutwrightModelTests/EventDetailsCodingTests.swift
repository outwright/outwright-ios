// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

/// Details and edits saved before Show as, Private and an answer's comment still read.
@Suite struct EventDetailsCodingTests {
    private func saved(transparency: String) -> Data {
        Data(#"""
            {"title":"Lunch","place":"","notes":"","start":{"utc":{"_0":0}},"end":{"utc":{"_0":3600}},
             "attendees":[],"status":{"confirmed":{}},"transparency":{"\#(transparency)":{}},"sequence":0}
            """#.utf8)
    }

    @Test func detailsSavedBeforeShowAsRead() throws {
        let free = try JSONDecoder().decode(EventDetails.self, from: saved(transparency: "free"))
        #expect(free.showAs == .free && !free.isPrivate)
        let busy = try JSONDecoder().decode(EventDetails.self, from: saved(transparency: "busy"))
        #expect(busy.showAs == .busy)
    }

    @Test func detailsRoundTrip() throws {
        let details = EventDetails(
            title: "Dentist", start: .utc(Date(timeIntervalSince1970: 0)), end: .utc(Date(timeIntervalSince1970: 60)),
            showAs: .away, isPrivate: true)
        let read = try JSONDecoder().decode(EventDetails.self, from: JSONEncoder().encode(details))
        #expect(read == details)
    }

    @Test func anAnswerSavedBeforeCommentsReads() throws {
        let old = Data(#"{"respond":{"_0":{"accepted":{}},"scope":{"event":{}},"sendReply":true}}"#.utf8)
        let edit = try JSONDecoder().decode(EventEdit.self, from: old)
        #expect(edit == .respond(.accepted, scope: .event, sendReply: true))
        let commented = EventEdit.respond(.declined, scope: .event, sendReply: true, comment: "Away")
        #expect(try JSONDecoder().decode(EventEdit.self, from: JSONEncoder().encode(commented)) == commented)
    }
}
