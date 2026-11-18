// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
@testable import OutwrightIMAP

@Suite struct BodyOutlineTests {
    private func summary(_ line: String) throws -> MessageSummary {
        let response = try IMAPParser.parse(Data(line.utf8))
        guard case let .data(_, _, values) = response else { throw IMAPError.protocolViolation }
        return try #require(FetchItems(values).summary())
    }

    @Test func anInvitationsCalendarPartIsSeenWithoutItsBody() throws {
        // iMIP as Outlook sends it: plain text, HTML, then the calendar.
        let found = try summary(
            "* 1 FETCH (UID 9 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 20 1 NIL NIL NIL)"
                + "(\"TEXT\" \"HTML\" (\"CHARSET\" \"utf-8\") NIL NIL \"QUOTED-PRINTABLE\" 90000 900 NIL NIL NIL)"
                + "(\"text\" \"calendar\" (\"charset\" \"utf-8\" \"method\" \"REQUEST\") NIL NIL \"BASE64\" 2400 31 NIL NIL NIL)"
                + " \"ALTERNATIVE\" (\"BOUNDARY\" \"b1\") NIL NIL))")
        #expect(found.calendarParts == [CalendarPartOutline(method: "REQUEST")])
    }

    @Test func aCalendarInAnAttachedMessageIsNotTheMessagesOwn() throws {
        let found = try summary(
            "* 1 FETCH (UID 9 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 20 1)"
                + "(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 900 (NIL \"Fwd\" NIL NIL NIL NIL NIL NIL NIL NIL)"
                + " (\"TEXT\" \"CALENDAR\" (\"METHOD\" \"REQUEST\") NIL NIL \"7BIT\" 400 10) 30)"
                + " \"MIXED\"))")
        #expect(found.calendarParts.isEmpty)
    }

    @Test func aMessageThatIsOnlyACalendarHasOnePartWithoutAMethod() throws {
        let found = try summary(
            "* 1 FETCH (UID 9 BODYSTRUCTURE (\"TEXT\" \"CALENDAR\" NIL NIL NIL \"7BIT\" 300 9))")
        #expect(found.calendarParts == [CalendarPartOutline(method: nil)])
    }

    @Test func noBodyStructureMeansNoCalendarParts() throws {
        #expect(try summary("* 1 FETCH (UID 9 FLAGS ())").calendarParts.isEmpty)
    }

    @Test func survivesArbitraryTrees() {
        var generator = SplitMix64(seed: 0xB0D7)
        let words = ["TEXT", "CALENDAR", "text", "calendar", "MESSAGE", "RFC822", "METHOD", "REQUEST", "NIL", "12",
                     "-1", "99999999999", "ALTERNATIVE", ""]
        func tree(_ depth: Int) -> IMAPValue {
            let pick = Int.random(in: 0..<10, using: &generator)
            if depth > 0, pick < 4 {
                return .list((0..<Int.random(in: 0..<12, using: &generator)).map { _ in tree(depth - 1) })
            }
            let word = words[Int.random(in: 0..<words.count, using: &generator)]
            return pick < 7 ? .atom(word) : .string(Data(word.utf8))
        }
        for _ in 0..<5000 {
            let items = FetchItems([.list([.atom("UID"), .atom("1"), .atom("BODYSTRUCTURE"), tree(8)])])
            let parts = items.summary()?.calendarParts ?? []
            #expect(parts.count <= BodyOutline.maxParts)
        }
    }
}
