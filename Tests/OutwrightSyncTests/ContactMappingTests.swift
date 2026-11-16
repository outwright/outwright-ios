// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightDAV
import OutwrightModel
import Testing

@testable import OutwrightSync

@Suite struct ContactMappingTests {
    private func card() throws -> VCard {
        let text = [
            "BEGIN:VCARD", "VERSION:4.0", "FN:Bo Lind",
            "item1.EMAIL;TYPE=work:a@example.org", "item1.X-ABLabel:Jobb",
            "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
            "TEL;TYPE=cell:+461", "TEL;TYPE=home:+462",
            "ADR;TYPE=work:;;Storgatan 1;Lund;;22222;", "ADR;TYPE=home:;;Lillgatan 2;Malmö;;21111;",
            "END:VCARD", "",
        ].joined(separator: "\r\n")
        let cards = try VCardReader.cards(Data(text.utf8))
        return try #require(cards.first)
    }

    @Test func anEditOfTheDetailsReachesTheEntryItWasReadFrom() throws {
        let card = try card()
        var details = ContactMapping.details(card.fields)
        details.emails.removeFirst()
        details.emails[0].value = "b2@example.org"
        details.phones.removeFirst()
        details.phones[0].value = "+4629"
        details.addresses.removeFirst()
        details.addresses[0].street = "Lillgatan 3"
        let edited = card.applying(ContactMapping.written(details))
        let emails = edited.properties.filter { $0.name == "EMAIL" }
        #expect(emails.map(\.group) == ["item2"])
        #expect(edited.properties.contains { $0.group == "item2" && $0.name == "X-ABLABEL" })
        #expect(!edited.properties.contains { $0.group == "item1" })
        #expect(edited.properties.filter { $0.name == "TEL" }.map { $0.parameters.flatMap(\.values) } == [["home"]])
        #expect(edited.properties.filter { $0.name == "ADR" }.map { $0.parameters.flatMap(\.values) } == [["home"]])
    }

    @Test func ourListOverAChangedServerCardIsMatchedByValue() throws {
        let base = try card()
        var ours = ContactMapping.written(ContactMapping.details(base.fields))
        ours.emails.removeFirst()
        // On the server, b moved first meanwhile: our entry's place in the base card means nothing there.
        var serverFields = base.fields
        serverFields.emails.reverse()
        let merged = ContactMapping.merged(base: base.fields, ours: ours, server: serverFields)
        #expect(merged.emails.map(\.origin) == [nil])
    }
}
