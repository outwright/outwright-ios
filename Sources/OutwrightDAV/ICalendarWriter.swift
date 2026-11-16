// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Writes iCalendar with CRLF line ends, folded at 75 octets on character boundaries.
public enum ICalendarWriter {
    public static func write(_ calendar: ICalComponent) -> Data {
        var out: [UInt8] = []
        append(calendar, depth: 1, to: &out)
        return Data(out)
    }

    private static func append(_ component: ICalComponent, depth: Int, to out: inout [UInt8]) {
        let name = ContentLine.token(component.name).uppercased()
        guard !name.isEmpty, depth <= DAVLimits.componentDepth else { return }
        ContentLine.appendLine("BEGIN:" + name, to: &out)
        for property in component.properties {
            if let text = serialize(property) { ContentLine.appendLine(text, to: &out) }
        }
        for child in component.components { append(child, depth: depth + 1, to: &out) }
        ContentLine.appendLine("END:" + name, to: &out)
    }

    private static func serialize(_ property: ICalProperty) -> String? {
        let name = ContentLine.token(property.name).uppercased()
        guard !name.isEmpty, name != "BEGIN", name != "END" else { return nil }
        // CR and NUL never reach the file; a line break inside a value becomes `\n`.
        let value = String(property.value.unicodeScalars.filter { $0 != "\r" && $0 != "\0" })
            .replacingOccurrences(of: "\n", with: "\\n")
        var group = ""
        if let name = property.group.map(ContentLine.token), !name.isEmpty { group = name + "." }
        return group + name + ContentLine.parameterText(property.parameters, bareWhenEmpty: true) + ":" + value
    }
}
