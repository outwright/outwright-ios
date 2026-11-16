// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightModel

@Suite struct ContactDetailsTests {
    private let base = ContactDetails(emails: [
        Labeled(label: "work", value: "a@example.org", origin: 0), Labeled(label: "home", value: "b@example.org", origin: 1),
    ])

    @Test func ourListKeepsWhereEachEntryCameFromWhenTheServerLeftItAlone() {
        var ours = base
        ours.emails.removeFirst()
        ours.emails[0].value = "b2@example.org"
        let merged = ContactDetails.merged(base: base, ours: ours, server: base)
        #expect(merged.emails.map(\.origin) == [1])
    }

    @Test func ourListForgetsWhereEntriesCameFromWhenTheServerChangedIt() {
        var ours = base
        ours.emails.removeFirst()
        ours.emails[0].value = "b2@example.org"
        var server = base
        server.emails.insert(Labeled(label: "", value: "c@example.org", origin: 0), at: 0)
        let merged = ContactDetails.merged(base: base, ours: ours, server: server)
        #expect(merged.emails == [Labeled(label: "home", value: "b2@example.org")])
        #expect(merged.emails.map(\.origin) == [nil], "its place was in the card as it was, not as it is now")
    }

    @Test func whereAnEntryCameFromIsKeptWhenSavedAndOldDataReadsWithoutIt() throws {
        let saved = try JSONEncoder().encode(base)
        #expect(try JSONDecoder().decode(ContactDetails.self, from: saved).emails.map(\.origin) == [0, 1])
        let old = Data(#"{"emails":[{"label":"work","value":"a@example.org"}]}"#.utf8)
        #expect(try JSONDecoder().decode(ContactDetails.self, from: old).emails.map(\.origin) == [nil])
    }

    @Test func whereAnEntryCameFromIsNotPartOfItsValue() {
        #expect(Labeled(label: "work", value: "a@example.org", origin: 3) == Labeled(label: "work", value: "a@example.org"))
        #expect(PostalAddress(street: "Storgatan 1", origin: 2) == PostalAddress(street: "Storgatan 1"))
    }
}
