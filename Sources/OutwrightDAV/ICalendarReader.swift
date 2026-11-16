// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Reads iCalendar (RFC 5545) into a tree. The input is hostile: sizes, nesting and counts are
/// capped, nothing is indexed unchecked, and nothing in a calendar is ever fetched.
public enum ICalendarReader {
    /// The VCALENDAR in `data`.
    public static func calendar(_ data: Data) throws(ICalError) -> ICalComponent {
        try read(data, Limits(bytes: DAVLimits.iCalendarBytes, components: DAVLimits.componentsPerResource))
    }

    /// The VCALENDAR of a whole published calendar (a subscription): one file, so larger caps.
    public static func feed(_ data: Data) throws(ICalError) -> ICalComponent {
        try read(data, Limits(bytes: DAVLimits.responseBytes, components: DAVLimits.feedComponents))
    }

    private struct Limits {
        let bytes: Int
        let components: Int
    }

    private static func read(_ data: Data, _ limits: Limits) throws(ICalError) -> ICalComponent {
        guard data.count <= limits.bytes else { throw .tooLarge }
        var builder = Builder(limit: limits.components)
        for line in try unfold(Array(data), limit: limits.bytes) {
            guard let parsed = ContentLine.parse(line, bareParametersAreTypes: false) else { continue }
            try builder.accept(parsed)
        }
        return try builder.finish()
    }

    private static func unfold(_ bytes: [UInt8], limit: Int) throws(ICalError) -> [[UInt8]] {
        do {
            return try ContentLine.unfold(bytes, limit: min(limit, DAVLimits.iCalendarLineBytes))
        } catch { throw .tooLarge }
    }

    /// Builds the tree with a stack of open components.
    private struct Builder {
        let limit: Int
        var stack: [ICalComponent] = []
        var root: ICalComponent?
        var count = 0

        mutating func accept(_ line: ParsedLine) throws(ICalError) {
            let value = ContentLine.decode(line.value.filter { $0 != 0 })
            switch line.name {
            case "BEGIN": try begin(value.trimmingCharacters(in: .whitespaces).uppercased())
            case "END": try end(value.trimmingCharacters(in: .whitespaces).uppercased())
            default:
                guard var top = stack.popLast() else { throw .malformed }
                guard top.properties.count < DAVLimits.componentProperties else { throw .tooLarge }
                top.properties.append(
                    ICalProperty(group: line.group, name: line.name, parameters: line.parameters, value: value))
                stack.append(top)
            }
        }

        private mutating func begin(_ name: String) throws(ICalError) {
            guard !name.isEmpty, root == nil else { throw .malformed }
            if stack.isEmpty { guard name == "VCALENDAR" else { throw .malformed } }
            guard stack.count < DAVLimits.componentDepth else { throw .tooLarge }
            count += 1
            guard count <= limit else { throw .tooLarge }
            if name == "VALARM", let parent = stack.last, parent.name == "VEVENT" {
                let alarms = parent.components.filter { $0.name == "VALARM" }.count
                guard alarms < DAVLimits.alarmsPerEvent else { throw .tooLarge }
            }
            stack.append(ICalComponent(name: name))
        }

        private mutating func end(_ name: String) throws(ICalError) {
            guard let top = stack.popLast(), top.name == name else { throw .malformed }
            if var parent = stack.popLast() {
                parent.components.append(top)
                stack.append(parent)
            } else {
                root = top
            }
        }

        func finish() throws(ICalError) -> ICalComponent {
            guard stack.isEmpty, let root else { throw .malformed }
            return root
        }
    }
}
