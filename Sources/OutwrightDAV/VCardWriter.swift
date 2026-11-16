// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Writes a vCard with CRLF line ends, folded at 75 octets on character boundaries.
public enum VCardWriter {
    public static func write(_ card: VCard) -> Data {
        var out: [UInt8] = []
        func line(_ text: String) { ContentLine.appendLine(text, to: &out) }
        line("BEGIN:VCARD")
        line("VERSION:" + (card.version == "4.0" ? "4.0" : "3.0"))
        for property in card.properties {
            if let text = serialize(property) { line(text) }
        }
        line("END:VCARD")
        return Data(out)
    }

    private static func serialize(_ property: VCardProperty) -> String? {
        let name = ContentLine.token(property.name)
        guard !name.isEmpty else { return nil }
        var text = ""
        if let group = property.group.map(ContentLine.token), !group.isEmpty { text += group + "." }
        text += name
        text += ContentLine.parameterText(property.parameters)
        let binary = property.parameters.contains {
            $0.name == "ENCODING" && $0.values.contains { ["B", "BASE64"].contains($0.uppercased()) }
        }
        let value = ContentLine.clean(property.value)
        let raw = binary || VCardText.keepsFileForm(property.name)
        text += ":" + (raw ? value.replacingOccurrences(of: "\n", with: "") : ContentLine.escape(value))
        return text
    }
}
