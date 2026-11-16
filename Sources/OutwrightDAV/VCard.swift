// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum VCardError: Error, Sendable, Equatable {
    case malformed
    case tooLarge
}

public struct VCardProperty: Sendable, Equatable {
    public var group: String?
    /// Upper-cased.
    public var name: String
    public var parameters: [VCardParameter]
    /// Text unescaped, except for structured and list properties (N, ADR, ORG, CATEGORIES,
    /// NICKNAME, GENDER) and URI-like ones (PHOTO, URL, UID, ...), which keep their file form.
    public var value: String

    public init(group: String? = nil, name: String, parameters: [VCardParameter] = [], value: String) {
        self.group = group
        self.name = name
        self.parameters = parameters
        self.value = value
    }

    /// The values of every TYPE parameter, in order.
    var types: [String] { parameters.filter { $0.name == "TYPE" }.flatMap(\.values) }
}

public struct VCard: Sendable, Equatable {
    /// "3.0" or "4.0".
    public var version: String
    /// Everything but BEGIN, VERSION and END, in file order.
    public var properties: [VCardProperty]

    public init(version: String, properties: [VCardProperty]) {
        self.version = version
        self.properties = properties
    }

    public var uid: String? { properties.first { $0.name == "UID" }?.value }

    public var isGroup: Bool {
        properties.contains {
            ($0.name == "KIND" || $0.name == "X-ADDRESSBOOKSERVER-KIND") && $0.value.lowercased() == "group"
        }
    }
}
