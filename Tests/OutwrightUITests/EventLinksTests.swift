// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightUI

@Suite struct EventLinksTests {
    @Test func findsHttpsMeetingLink() {
        let found = EventLinks.find(in: "Video call: https://meet.example.org/j/123?pwd=abc\nDial in +46 8 555 010 20")
        #expect(found.map(\.absoluteString) == ["https://meet.example.org/j/123?pwd=abc"])
        #expect(EventLinks.find(in: "see http://intranet.example.org/room").count == 1)
    }

    @Test func ignoresOtherSchemes() {
        let text = "javascript:alert(1) file:///etc/passwd tel:+46855501020 mailto:bo@example.org ftp://example.org/x"
        #expect(EventLinks.find(in: text).isEmpty)
    }

    @Test func keepsAtMostTenAndNoRepeats() {
        let text = (0..<30).map { "https://example.org/\($0 % 15)" }.joined(separator: " ")
        let found = EventLinks.find(in: text)
        #expect(found.count == 10)
        #expect(Set(found).count == 10)
    }

    @Test func teamsLinkIsTheMeeting() throws {
        let urls = [
            "https://example.org/agenda", "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0",
            "https://us02web.zoom.us/j/123"
        ].compactMap(URL.init(string:))
        #expect(EventLinks.meeting(in: urls)?.host() == "teams.microsoft.com")
    }

    @Test func meetingHostsMatchOnADotBoundaryOverHTTPSOnly() {
        func meeting(_ text: String) -> String? {
            EventLinks.meeting(in: [URL(string: text)].compactMap { $0 })?.absoluteString
        }
        #expect(meeting("https://us02web.zoom.us/j/123") != nil)
        #expect(meeting("https://meet.google.com/abc-defg-hij") != nil)
        #expect(meeting("https://whereby.com/room") != nil)
        #expect(meeting("https://meet.jit.si/Room") != nil)
        #expect(meeting("https://teams.live.com/meet/123") != nil)
        #expect(meeting("https://video.example.org/rooms/join/42") != nil, "a path with /join")
        #expect(meeting("https://evilzoom.us/j/123") == nil)
        #expect(meeting("https://zoom.us.example.org/j/123") == nil)
        #expect(meeting("http://us02web.zoom.us/j/123") == nil, "only https")
        #expect(meeting("https://example.org/joiner") == nil)
        #expect(meeting("https://example.org/agenda") == nil)
    }

    @Test func joinShowsFromAQuarterBeforeTheStartUntilTheEnd() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let occurrence = Occurrence(
            recurrenceID: nil,
            details: EventDetails(
                title: "Call", notes: "https://meet.google.com/abc-defg-hij", start: .utc(start),
                end: .utc(start.addingTimeInterval(1_800))),
            start: start, end: start.addingTimeInterval(1_800))
        #expect(EventLinks.joinable(occurrence, now: start.addingTimeInterval(-16 * 60)) == nil)
        #expect(EventLinks.joinable(occurrence, now: start.addingTimeInterval(-15 * 60)) != nil)
        #expect(EventLinks.joinable(occurrence, now: start.addingTimeInterval(1_799)) != nil)
        #expect(EventLinks.joinable(occurrence, now: start.addingTimeInterval(1_800)) == nil)
        var plain = occurrence
        plain.details.notes = "https://example.org/agenda"
        #expect(EventLinks.joinable(plain, now: start) == nil)
    }

    @Test func thePlaceOpensMapsWithItsWholeText() throws {
        let url = try #require(EventLinks.maps(for: "Café Bo & Co, Drottninggatan 1#2"))
        #expect(url.scheme == "maps")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.map(\.name) == ["q"])
        #expect(query.first?.value == "Café Bo & Co, Drottninggatan 1#2")
        #expect(EventLinks.maps(for: "  ") == nil)
        #expect(EventLinks.maps(for: "https://teams.microsoft.com/l/meetup-join/x") == nil)
    }

    @Test func survivesArbitraryText() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let scalars = (0..<Int.random(in: 0..<300, using: &generator)).compactMap { _ in
                UnicodeScalar(UInt32.random(in: 0..<0x2_0000, using: &generator))
            }
            let text = String(String.UnicodeScalarView(scalars))
            #expect(EventLinks.find(in: text).allSatisfy { ["http", "https"].contains($0.scheme ?? "") })
        }
    }
}
