// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

public struct LabeledValue: Sendable, Equatable {
    /// The first TYPE, lower-cased; "" when none.
    public var label: String
    public var value: String
    /// Where the entry was read from: its place among the card's properties of its kind (nil for
    /// one added since). An edit is written back to that property, whatever else changed.
    public var origin: Int?

    public init(label: String, value: String, origin: Int? = nil) {
        self.label = label
        self.value = value
        self.origin = origin
    }

    /// The entry itself; where it was read from is not part of it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
    }
}

public struct VCardAddress: Sendable, Equatable {
    public var label: String
    public var street: String
    public var locality: String
    public var region: String
    public var postalCode: String
    public var country: String
    /// Where the address was read from, as for `LabeledValue.origin`.
    public var origin: Int?

    public init(
        label: String = "", street: String = "", locality: String = "", region: String = "",
        postalCode: String = "", country: String = "", origin: Int? = nil
    ) {
        self.label = label
        self.street = street
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.origin = origin
    }

    /// The address itself; where it was read from is not part of it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.street == rhs.street && lhs.locality == rhs.locality
            && lhs.region == rhs.region && lhs.postalCode == rhs.postalCode && lhs.country == rhs.country
    }
}

/// The part of a card the app shows and edits.
public struct VCardFields: Sendable, Equatable {
    public var givenName: String
    public var familyName: String
    public var formattedName: String
    public var organization: String
    public var note: String
    public var emails: [LabeledValue]
    public var phones: [LabeledValue]
    public var addresses: [VCardAddress]
    /// An inline photo only; a photo given as a URI is never read, let alone fetched. Read-only:
    /// `VCard.applying` leaves the PHOTO property as it is.
    public var photo: Data?

    public init(
        givenName: String = "", familyName: String = "", formattedName: String = "", organization: String = "",
        note: String = "", emails: [LabeledValue] = [], phones: [LabeledValue] = [],
        addresses: [VCardAddress] = [], photo: Data? = nil
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.formattedName = formattedName
        self.organization = organization
        self.note = note
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.photo = photo
    }
}

// MARK: - Text forms

enum VCardText {
    /// Properties whose value keeps its escaped file form, so components can be split.
    static let structured: Set<String> = ["N", "ADR", "ORG", "CATEGORIES", "NICKNAME", "GENDER"]
    /// Properties that are URIs or binary: no text escaping either way.
    static let verbatim: Set<String> = [
        "PHOTO", "LOGO", "SOUND", "KEY", "URL", "UID", "SOURCE", "MEMBER", "IMPP", "RELATED", "TZ", "GEO",
        "CALURI", "CALADRURI", "FBURL", "X-ADDRESSBOOKSERVER-MEMBER"
    ]
    static func keepsFileForm(_ name: String) -> Bool { structured.contains(name) || verbatim.contains(name) }

    /// Splits on `;` that is not escaped; the parts keep their escapes.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var escaped = false
        for scalar in text.unicodeScalars {
            if escaped {
                current.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                current.append(scalar)
                escaped = true
            } else if scalar == ";" {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        parts.append(String(current))
        return parts
    }

    static func component(_ parts: [String], _ index: Int) -> String {
        parts.indices.contains(index) ? ContentLine.unescape(parts[index]) : ""
    }

    static func padded(_ parts: [String], to count: Int) -> [String] {
        parts + Array(repeating: "", count: max(0, count - parts.count))
    }
}

// MARK: - Reading the fields

extension VCard {
    private func first(_ name: String) -> VCardProperty? { properties.first { $0.name == name } }

    /// TYPE values that say nothing about what the entry is for.
    private static let noiseTypes: Set<String> = ["pref", "internet"]

    private static func label(_ property: VCardProperty) -> String {
        property.types.map { $0.lowercased() }.first { !noiseTypes.contains($0) } ?? ""
    }

    public var fields: VCardFields {
        var fields = VCardFields()
        if let name = first("N") {
            let parts = VCardText.split(name.value)
            fields.familyName = VCardText.component(parts, 0)
            fields.givenName = VCardText.component(parts, 1)
        }
        fields.formattedName = first("FN")?.value ?? ""
        if let org = first("ORG") { fields.organization = VCardText.component(VCardText.split(org.value), 0) }
        fields.note = first("NOTE")?.value ?? ""
        for property in properties {
            switch property.name {
            case "EMAIL":
                fields.emails.append(
                    LabeledValue(label: Self.label(property), value: property.value, origin: fields.emails.count))
            case "TEL":
                fields.phones.append(
                    LabeledValue(label: Self.label(property), value: property.value, origin: fields.phones.count))
            case "ADR":
                let parts = VCardText.split(property.value)
                fields.addresses.append(VCardAddress(
                    label: Self.label(property), street: VCardText.component(parts, 2),
                    locality: VCardText.component(parts, 3), region: VCardText.component(parts, 4),
                    postalCode: VCardText.component(parts, 5), country: VCardText.component(parts, 6),
                    origin: fields.addresses.count))
            default: break
            }
        }
        fields.photo = properties.lazy.filter { $0.name == "PHOTO" }.compactMap(Self.inlinePhoto).first
        return fields
    }

    private static func inlinePhoto(_ property: VCardProperty) -> Data? {
        let value = property.value
        let payload: Substring
        if value.prefix(5).lowercased() == "data:" {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            guard value[..<comma].lowercased().contains(";base64") else { return nil }
            payload = value[value.index(after: comma)...]
        } else if property.parameters.contains(where: {
            $0.name == "ENCODING" && $0.values.contains { ["b", "base64"].contains($0.lowercased()) }
        }) {
            payload = value[...]
        } else {
            return nil
        }
        guard payload.utf8.count <= DAVLimits.photoBytes / 3 * 4 + 16 else { return nil }
        guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
            data.count <= DAVLimits.photoBytes
        else { return nil }
        return data
    }
}

// MARK: - Applying edits

extension VCard {
    /// The card with FN, N, ORG, EMAIL, TEL, ADR and NOTE brought to `fields`. A field that did
    /// not change is left alone, and every other property stays as it came, in order.
    public func applying(_ fields: VCardFields) -> VCard {
        let old = self.fields
        var props = properties
        var removedGroups: Set<String> = []

        updateSingle("FN", &props, changed: old.formattedName != fields.formattedName) { existing in
            fields.formattedName.isEmpty ? nil : Self.make(existing, "FN", ContentLine.clean(fields.formattedName))
        }
        updateSingle("NOTE", &props, changed: old.note != fields.note) { existing in
            fields.note.isEmpty ? nil : Self.make(existing, "NOTE", ContentLine.clean(fields.note))
        }
        updateSingle(
            "N", &props, changed: old.familyName != fields.familyName || old.givenName != fields.givenName
        ) { existing in
            var parts = VCardText.padded(existing.map { VCardText.split($0.value) } ?? [], to: 5)
            parts[0] = ContentLine.escape(fields.familyName)
            parts[1] = ContentLine.escape(fields.givenName)
            if parts.allSatisfy(\.isEmpty) { return nil }
            return Self.make(existing, "N", parts.joined(separator: ";"))
        }
        updateSingle("ORG", &props, changed: old.organization != fields.organization) { existing in
            if fields.organization.isEmpty && (existing.map { VCardText.split($0.value).count } ?? 0) <= 1 {
                return nil
            }
            var parts = existing.map { VCardText.split($0.value) } ?? [""]
            parts[0] = ContentLine.escape(fields.organization)
            return Self.make(existing, "ORG", parts.joined(separator: ";"))
        }
        updateList("EMAIL", &props, &removedGroups, change: (old.emails, fields.emails)) { existing, item in
            Self.make(existing, "EMAIL", ContentLine.clean(item.value), label: item.label)
        }
        updateList("TEL", &props, &removedGroups, change: (old.phones, fields.phones)) { existing, item in
            Self.make(existing, "TEL", ContentLine.clean(item.value), label: item.label)
        }
        updateList("ADR", &props, &removedGroups, change: (old.addresses, fields.addresses)) { existing, item in
            var parts = VCardText.padded(existing.map { VCardText.split($0.value) } ?? [], to: 7)
            parts[2] = ContentLine.escape(item.street)
            parts[3] = ContentLine.escape(item.locality)
            parts[4] = ContentLine.escape(item.region)
            parts[5] = ContentLine.escape(item.postalCode)
            parts[6] = ContentLine.escape(item.country)
            return Self.make(existing, "ADR", parts.joined(separator: ";"), label: item.label)
        }
        for group in removedGroups where !props.contains(where: { $0.group == group && $0.name != "X-ABLABEL" }) {
            props.removeAll { $0.group == group }
        }
        return VCard(version: version, properties: props)
    }

    /// A property built from `existing` (keeping its group and parameters) with a new value. A
    /// changed label replaces only the TYPE value that was the label; the other types stay.
    private static func make(
        _ existing: VCardProperty?, _ name: String, _ value: String, label: String? = nil
    ) -> VCardProperty {
        var property = existing ?? VCardProperty(name: name, value: value)
        property.value = value
        let old = existing.map(Self.label) ?? ""
        guard let label, label != old else { return property }
        for (index, parameter) in property.parameters.enumerated() where parameter.name == "TYPE" {
            guard !old.isEmpty, let place = parameter.values.firstIndex(where: { $0.lowercased() == old }) else {
                continue
            }
            var values = parameter.values
            if label.isEmpty { values.remove(at: place) } else { values[place] = label }
            if values.isEmpty {
                property.parameters.remove(at: index)
            } else {
                property.parameters[index].values = values
            }
            return property
        }
        guard !label.isEmpty else { return property }
        if let index = property.parameters.firstIndex(where: { $0.name == "TYPE" }) {
            property.parameters[index].values.insert(label, at: 0)
        } else {
            property.parameters.insert(VCardParameter(name: "TYPE", values: [label]), at: 0)
        }
        return property
    }

    private func updateSingle(
        _ name: String, _ props: inout [VCardProperty], changed: Bool, build: (VCardProperty?) -> VCardProperty?
    ) {
        guard changed else { return }
        let index = props.firstIndex { $0.name == name }
        let built = build(index.map { props[$0] })
        switch (index, built) {
        case let (index?, built?): props[index] = built
        case let (index?, nil): props.remove(at: index)
        case let (nil, built?): props.append(built)
        case (nil, nil): break
        }
    }

    /// Brings the `name` properties from `old` to `new`. Entries are matched first by `origin`
    /// (the property an entry was read from), then by being equal, then by `matchKey` (the same
    /// value under another label), then in order; a matched entry
    /// keeps its own property (group, parameters), an unmatched old one is removed and an
    /// unmatched new one added after the last.
    private func updateList<Item: ListEntry>(
        _ name: String, _ props: inout [VCardProperty], _ removedGroups: inout Set<String>,
        change: (old: [Item], new: [Item]), build: (VCardProperty?, Item) -> VCardProperty
    ) {
        let (fullOld, new) = change
        guard fullOld != new else { return }
        let indices = props.indices.filter { props[$0].name == name }
        let old = Array(fullOld.prefix(indices.count))
        let match = Self.match(old, new)
        for (newIndex, oldIndex) in match where old[oldIndex] != new[newIndex] {
            props[indices[oldIndex]] = build(props[indices[oldIndex]], new[newIndex])
        }
        let matchedOld = Set(match.values)
        let added = new.indices.filter { match[$0] == nil }.map { build(nil, new[$0]) }
        props.insert(contentsOf: added, at: indices.last.map { $0 + 1 } ?? props.endIndex)
        for oldIndex in old.indices.reversed() where !matchedOld.contains(oldIndex) {
            let index = indices[oldIndex]
            if let group = props[index].group { removedGroups.insert(group) }
            props.remove(at: index)
        }
    }

    /// New position to old position: entries read from an old one, then equal entries, then
    /// entries with the same key, then the rest in order.
    private static func match<Item: ListEntry>(_ old: [Item], _ new: [Item]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var used = Set<Int>()
        for newIndex in new.indices {
            guard let origin = new[newIndex].origin, old.indices.contains(origin), !used.contains(origin) else {
                continue
            }
            result[newIndex] = origin
            used.insert(origin)
        }
        for byKey in [false, true] {
            for newIndex in new.indices where result[newIndex] == nil {
                let wanted = new[newIndex]
                let found = old.indices.first { index in
                    !used.contains(index) && (byKey ? old[index].matchKey == wanted.matchKey : old[index] == wanted)
                }
                if let oldIndex = found {
                    result[newIndex] = oldIndex
                    used.insert(oldIndex)
                }
            }
        }
        let freeOld = old.indices.filter { !used.contains($0) }
        let freeNew = new.indices.filter { result[$0] == nil }
        for (newIndex, oldIndex) in zip(freeNew, freeOld) {
            result[newIndex] = oldIndex
        }
        return result
    }
}

/// An entry of a list field (EMAIL, TEL, ADR): `matchKey` is the entry without its label, so a
/// relabelled entry is still found as the same one.
protocol ListEntry: Equatable {
    var matchKey: String { get }
    var origin: Int? { get }
}

extension LabeledValue: ListEntry {
    var matchKey: String { value }
}

extension VCardAddress: ListEntry {
    var matchKey: String { [street, locality, region, postalCode, country].joined(separator: "\u{1F}") }
}
