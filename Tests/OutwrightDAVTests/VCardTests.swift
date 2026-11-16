// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

func vcf(_ lines: [String], version: String = "4.0") -> Data {
    Data((["BEGIN:VCARD", "VERSION:\(version)"] + lines + ["END:VCARD", ""]).joined(separator: "\r\n").utf8)
}

func firstCard(_ data: Data) throws -> VCard {
    let all = try VCardReader.cards(data)
    try #require(all.count == 1)
    return all[0]
}

@Suite struct VCardTests {
    @Test func readsVersion4Card() throws {
        let card = try firstCard(vcf([
            "UID:u-1", "FN:Bo Lind", "N:Lind;Bo;;;", "ORG:Example AB",
            "EMAIL;TYPE=work:bo@example.org", "EMAIL:b@example.org",
            "TEL;TYPE=cell:+46701234567",
            "ADR;TYPE=home:;;Storgatan 1;Lund;Skåne;22222;Sverige",
            "NOTE:a\\, b\\nc",
        ]))
        let fields = card.fields
        #expect(card.version == "4.0")
        #expect(card.uid == "u-1")
        #expect(fields.familyName == "Lind")
        #expect(fields.givenName == "Bo")
        #expect(fields.formattedName == "Bo Lind")
        #expect(fields.organization == "Example AB")
        #expect(fields.emails == [LabeledValue(label: "work", value: "bo@example.org"), LabeledValue(label: "", value: "b@example.org")])
        #expect(fields.phones == [LabeledValue(label: "cell", value: "+46701234567")])
        #expect(fields.addresses == [VCardAddress(label: "home", street: "Storgatan 1", locality: "Lund", region: "Skåne", postalCode: "22222", country: "Sverige")])
        #expect(fields.note == "a, b\nc")
    }

    @Test func readsVersion3QuotedPrintableAndCharset() throws {
        let raw = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=ISO-8859-1:=E5=E4\r\nEND:VCARD\r\n".utf8)
        let card = try firstCard(raw)
        #expect(card.version == "3.0")
        #expect(card.fields.note == "åä")
    }

    @Test func unfoldsContinuationLines() throws {
        let raw = Data("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Anna\r\n  Berg\nNOTE:one\n\ttwo\r\nEND:VCARD\r\n".utf8)
        let card = try firstCard(raw)
        #expect(card.fields.formattedName == "Anna Berg")
        #expect(card.fields.note == "onetwo")
    }

    @Test func inlinePhotoIsRead() throws {
        let bytes = Data((0..<200).map { UInt8($0 % 251) })
        let b64 = bytes.base64EncodedString()
        let v4 = try firstCard(vcf(["PHOTO:data:image/jpeg;base64,\(b64)"]))
        #expect(v4.fields.photo == bytes)
        let v3 = try firstCard(vcf(["PHOTO;ENCODING=b;TYPE=JPEG:\(b64)"], version: "3.0"))
        #expect(v3.fields.photo == bytes)
    }

    @Test func uriPhotoIsNeverRead() throws {
        let card = try firstCard(vcf(["FN:A", "PHOTO:https://tracker.example.org/p.jpg"]))
        #expect(card.fields.photo == nil)
        #expect(card.fields.formattedName == "A")
    }

    @Test func oversizedPhotoIsDropped() throws {
        let b64 = Data(count: 600 * 1024).base64EncodedString()
        let card = try firstCard(vcf(["FN:A", "PHOTO;ENCODING=b:\(b64)", "NOTE:kept"], version: "3.0"))
        #expect(card.fields.photo == nil)
        #expect(card.fields.formattedName == "A")
        #expect(card.fields.note == "kept")
    }

    @Test func editKeepsUnknownProperties() throws {
        let card = try firstCard(vcf([
            "FN:Bo Lind", "X-SOCIAL;TYPE=x:@bo", "item1.EMAIL;TYPE=work:bo@example.org",
            "item1.X-ABLabel:Jobb", "BDAY:19800101", "CATEGORIES:a,b", "N:Lind;Bo;;;",
        ]))
        var fields = card.fields
        fields.phones.append(LabeledValue(label: "cell", value: "+4670"))
        let edited = card.applying(fields)
        let reread = try firstCard(VCardWriter.write(edited))
        #expect(reread.properties.filter { $0.name != "TEL" } == card.properties)
        #expect(reread.fields.phones == [LabeledValue(label: "cell", value: "+4670")])
        #expect(reread.fields.emails == card.fields.emails)
    }

    @Test func editChangesAndRemovesFields() throws {
        let card = try firstCard(vcf([
            "FN:Bo Lind", "N:Lind;Bo;Extra;Dr;", "EMAIL:a@example.org", "EMAIL:b@example.org", "NOTE:old",
        ]))
        var fields = card.fields
        fields.givenName = "Bosse"
        fields.emails = [LabeledValue(label: "home", value: "b@example.org")]
        fields.note = ""
        let reread = try firstCard(VCardWriter.write(card.applying(fields)))
        #expect(reread.fields.givenName == "Bosse")
        #expect(reread.fields.familyName == "Lind")
        #expect(reread.fields.emails == [LabeledValue(label: "home", value: "b@example.org")])
        #expect(reread.fields.note == "")
        #expect(reread.properties.contains { $0.name == "N" && $0.value == "Lind;Bosse;Extra;Dr;" })
        #expect(!reread.properties.contains { $0.name == "NOTE" })
    }

    @Test func writeFoldsAt75OctetsAndUsesCRLF() throws {
        let long = String(repeating: "åäö漢字x", count: 60)
        let card = try firstCard(vcf(["FN:Z", "NOTE:\(long)"]))
        let data = VCardWriter.write(card)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\r\n"))
        let lines = text.components(separatedBy: "\r\n").dropLast()
        #expect(lines.count > 3)
        for line in lines { #expect(line.utf8.count <= 75) }
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let reread = try firstCard(data)
        #expect(reread.fields.note == long)
    }

    @Test func writeKeepsVersion3() throws {
        let card = try firstCard(vcf(["FN:A"], version: "3.0"))
        let text = String(decoding: VCardWriter.write(card), as: UTF8.self)
        #expect(text.contains("VERSION:3.0\r\n"))
    }

    @Test func groupCardIsRecognised() throws {
        #expect(try firstCard(vcf(["FN:G", "KIND:group"])).isGroup)
        #expect(try firstCard(vcf(["FN:G", "X-ADDRESSBOOKSERVER-KIND:group"], version: "3.0")).isGroup)
        #expect(try !firstCard(vcf(["FN:G"])).isGroup)
    }

    @Test func parameterQuotingAndCaretEscapesRoundTrip() throws {
        let card = try firstCard(vcf(["ADR;LABEL=\"Line 1^nLine 2: ^'x^'\";TYPE=home:;;S;L;;;"]))
        let label = card.properties.first?.parameters.first { $0.name == "LABEL" }
        #expect(label?.values == ["Line 1\nLine 2: \"x\""])
        let reread = try firstCard(VCardWriter.write(card))
        #expect(reread == card)
    }

    @Test func tooManyCardsAndOversizedInputAreRejected() throws {
        let one = String(decoding: vcf(["FN:A"]), as: UTF8.self)
        #expect(throws: VCardError.tooLarge) { try VCardReader.cards(Data(String(repeating: one, count: 17).utf8)) }
        #expect(try VCardReader.cards(Data(String(repeating: one, count: 16).utf8)).count == 16)
        #expect(throws: VCardError.tooLarge) { try VCardReader.cards(Data(count: DAVLimits.vCardBytes + 1)) }
        #expect(throws: VCardError.malformed) { try VCardReader.cards(Data("hello".utf8)) }
    }

    @Test func rewritingDecodedQuotedPrintableAndLatin1KeepsText() throws {
        let raw = Data(("BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=ISO-8859-1:=E5=E4 =3DE5\r\n"
            + "FN;CHARSET=ISO-8859-1:").utf8) + Data([0xE5, 0xE4]) + Data("\r\nEND:VCARD\r\n".utf8)
        let card = try firstCard(raw)
        #expect(card.fields.note == "åä =E5")
        #expect(card.fields.formattedName == "åä")
        let again = try firstCard(VCardWriter.write(card))
        #expect(again.properties == card.properties)
        #expect(again.fields.note == "åä =E5")
        #expect(again.fields.formattedName == "åä")
    }

    @Test func unchangedLabelKeepsItsTypeParameter() throws {
        let card = try firstCard(vcf(["TEL;TYPE=cell,voice:+4670"]))
        var fields = card.fields
        fields.phones[0].value = "+4671"
        let edited = card.applying(fields)
        #expect(edited.properties.first?.parameters == [VCardParameter(name: "TYPE", values: ["cell", "voice"])])
        #expect(edited.fields.phones == [LabeledValue(label: "cell", value: "+4671")])
    }

    @Test func removingFirstEntryLeavesTheNextExactlyAsItWas() throws {
        let card = try firstCard(vcf([
            "FN:Bo Lind",
            "item1.EMAIL;TYPE=work;PREF=1:a@example.org", "item1.X-ABLabel:Jobb",
            "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
            "TEL;TYPE=cell;PREF=1:+461", "TEL;TYPE=home,voice:+462",
            "item3.ADR;TYPE=work:;;Storgatan 1;Lund;;22222;", "item3.X-ABLabel:Kontor",
            "item4.ADR:;;Lillgatan 2;Malmö;;21111;", "item4.X-ABLabel:Stuga",
        ]))
        var fields = card.fields
        fields.emails.removeFirst()
        fields.phones.removeFirst()
        fields.addresses.removeFirst()
        let reread = try firstCard(VCardWriter.write(card.applying(fields)))
        let kept = try firstCard(vcf([
            "FN:Bo Lind",
            "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
            "TEL;TYPE=home,voice:+462",
            "item4.ADR:;;Lillgatan 2;Malmö;;21111;", "item4.X-ABLabel:Stuga",
        ]))
        #expect(reread.properties == kept.properties)
    }

    @Test func removingAnEntryAndRelabellingAnotherTouchesOnlyThose() throws {
        let card = try firstCard(vcf([
            "EMAIL;TYPE=work;PREF=1:a@example.org", "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
        ]))
        var fields = card.fields
        fields.emails = [LabeledValue(label: "other", value: "b@example.org")]
        let edited = card.applying(fields)
        #expect(edited.properties.map(\.group) == ["item2", "item2"])
        #expect(edited.fields.emails == [LabeledValue(label: "other", value: "b@example.org")])
    }

    @Test func removingOneEntryAndEditingAnotherKeepsEachItsOwnProperty() throws {
        let card = try firstCard(vcf([
            "FN:Bo Lind",
            "item1.EMAIL;TYPE=work;PREF=1:a@example.org", "item1.X-ABLabel:Jobb",
            "item2.EMAIL;TYPE=home:b@example.org", "item2.X-ABLabel:Privat",
            "TEL;TYPE=cell;PREF=1:+461", "TEL;TYPE=home,voice:+462",
            "item3.ADR;TYPE=work:;;Storgatan 1;Lund;;22222;", "item3.X-ABLabel:Kontor",
            "item4.ADR:;;Lillgatan 2;Malmö;;21111;", "item4.X-ABLabel:Stuga",
        ]))
        var fields = card.fields
        fields.emails.removeFirst()
        fields.emails[0].value = "b2@example.org"
        fields.phones.removeFirst()
        fields.phones[0].value = "+4629"
        fields.addresses.removeFirst()
        fields.addresses[0].street = "Lillgatan 3"
        let reread = try firstCard(VCardWriter.write(card.applying(fields)))
        let kept = try firstCard(vcf([
            "FN:Bo Lind",
            "item2.EMAIL;TYPE=home:b2@example.org", "item2.X-ABLabel:Privat",
            "TEL;TYPE=home,voice:+4629",
            "item4.ADR:;;Lillgatan 3;Malmö;;21111;", "item4.X-ABLabel:Stuga",
        ]))
        #expect(reread.properties == kept.properties)
    }

    @Test func changedLabelReplacesOnlyTheLabelType() throws {
        let card = try firstCard(vcf(["TEL;TYPE=cell,voice;PREF=1:+4670"]))
        var fields = card.fields
        fields.phones[0].label = "work"
        let edited = card.applying(fields)
        #expect(edited.properties.first?.parameters == [
            VCardParameter(name: "TYPE", values: ["work", "voice"]), VCardParameter(name: "PREF", values: ["1"]),
        ])
        fields.phones[0].label = ""
        let cleared = card.applying(fields)
        #expect(cleared.properties.first?.parameters == [
            VCardParameter(name: "TYPE", values: ["voice"]), VCardParameter(name: "PREF", values: ["1"]),
        ])
    }
}
