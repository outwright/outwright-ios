// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum ICalError: Error, Sendable, Equatable {
    case malformed
    case tooLarge
}

/// One content line of an iCalendar component.
public struct ICalProperty: Sendable, Equatable {
    public var group: String?
    /// Upper-cased.
    public var name: String
    public var parameters: [ContentParameter]
    /// As in the file, still escaped.
    public var value: String

    public init(group: String? = nil, name: String, parameters: [ContentParameter] = [], value: String) {
        self.group = group
        self.name = name
        self.parameters = parameters
        self.value = value
    }

    /// A TEXT property: `text` is escaped into the value.
    public init(group: String? = nil, name: String, parameters: [ContentParameter] = [], text: String) {
        self.init(group: group, name: name, parameters: parameters, value: ContentLine.escape(text))
    }

    /// The value read as TEXT: escapes resolved.
    public var text: String { ContentLine.unescape(value) }

    /// The first value of the first parameter called `name`.
    public func parameter(_ name: String) -> String? {
        let wanted = name.uppercased()
        return parameters.first { $0.name == wanted }?.values.first
    }
}

/// A component (VCALENDAR, VEVENT, VTIMEZONE, VALARM, ...) with its properties and children, in
/// file order. Editing one property leaves the rest as it was read.
public struct ICalComponent: Sendable, Equatable {
    /// Upper-cased.
    public var name: String
    public var properties: [ICalProperty]
    public var components: [ICalComponent]

    public init(name: String, properties: [ICalProperty] = [], components: [ICalComponent] = []) {
        self.name = name
        self.properties = properties
        self.components = components
    }

    public func first(_ name: String) -> ICalProperty? {
        let wanted = name.uppercased()
        return properties.first { $0.name == wanted }
    }

    public func all(_ name: String) -> [ICalProperty] {
        let wanted = name.uppercased()
        return properties.filter { $0.name == wanted }
    }

    /// Swaps every property called `name` for `new`, which takes the place of the first of them
    /// (or goes last when there was none).
    public func replacing(_ name: String, with new: [ICalProperty]) -> ICalComponent {
        let wanted = name.uppercased()
        var result = self
        result.properties = []
        var placed = false
        for property in properties {
            guard property.name == wanted else {
                result.properties.append(property)
                continue
            }
            if !placed {
                result.properties.append(contentsOf: new)
                placed = true
            }
        }
        if !placed { result.properties.append(contentsOf: new) }
        return result
    }
}
