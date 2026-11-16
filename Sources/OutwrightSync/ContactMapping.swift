// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightDAV
public import OutwrightModel

/// Between the vCard fields the DAV layer reads and the details the model keeps.
public enum ContactMapping {
    public static func details(_ fields: VCardFields) -> ContactDetails {
        ContactDetails(
            givenName: fields.givenName, familyName: fields.familyName, displayName: fields.formattedName,
            organization: fields.organization, note: fields.note,
            emails: fields.emails.map { Labeled(label: $0.label, value: $0.value, origin: $0.origin) },
            phones: fields.phones.map { Labeled(label: $0.label, value: $0.value, origin: $0.origin) },
            addresses: fields.addresses.map {
                PostalAddress(
                    label: $0.label, street: $0.street, locality: $0.locality, region: $0.region,
                    postalCode: $0.postalCode, country: $0.country, origin: $0.origin)
            })
    }

    public static func fields(_ details: ContactDetails, photo: Data?) -> VCardFields {
        VCardFields(
            givenName: details.givenName, familyName: details.familyName, formattedName: details.displayName,
            organization: details.organization, note: details.note,
            emails: details.emails.map { LabeledValue(label: $0.label, value: $0.value, origin: $0.origin) },
            phones: details.phones.map { LabeledValue(label: $0.label, value: $0.value, origin: $0.origin) },
            addresses: details.addresses.map {
                VCardAddress(
                    label: $0.label, street: $0.street, locality: $0.locality, region: $0.region,
                    postalCode: $0.postalCode, country: $0.country, origin: $0.origin)
            },
            photo: photo)
    }

    /// The fields as a card is written with them. FN is required (RFC 6350, and 3.0 too): without
    /// a display name it is the details' name.
    static func written(_ details: ContactDetails, photo: Data? = nil) -> VCardFields {
        var fields = fields(details, photo: photo)
        if fields.formattedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.formattedName = details.name
        }
        return fields
    }

    /// A new vCard 4.0 with a fresh `urn:uuid` UID.
    public static func newCard(_ details: ContactDetails) -> VCard {
        let fields = written(details)
        let uid = "urn:uuid:" + UUID().uuidString.lowercased()
        return VCard(version: "4.0", properties: [VCardProperty(name: "UID", value: uid)]).applying(fields)
    }

    /// The server's fields with the owner's changes since `base` laid over them: a field the
    /// owner left as it was in `base` keeps what the server has now.
    static func merged(base: VCardFields, ours: VCardFields, server: VCardFields) -> VCardFields {
        var result = server
        func take<T: Equatable>(_ path: WritableKeyPath<VCardFields, T>) {
            if ours[keyPath: path] != base[keyPath: path] {
                result[keyPath: path] = ours[keyPath: path]
            }
        }
        take(\.givenName)
        take(\.familyName)
        take(\.formattedName)
        take(\.organization)
        take(\.note)
        takeList(\.emails, &result, base: base, ours: ours, server: server)
        takeList(\.phones, &result, base: base, ours: ours, server: server)
        takeList(\.addresses, &result, base: base, ours: ours, server: server)
        return result
    }

    /// Our list when we changed it. Where its entries were read from points into the base card,
    /// so over a server card whose list changed meanwhile they are matched by value instead.
    private static func takeList<Item: OriginEntry>(
        _ path: WritableKeyPath<VCardFields, [Item]>, _ result: inout VCardFields,
        base: VCardFields, ours: VCardFields, server: VCardFields
    ) {
        guard ours[keyPath: path] != base[keyPath: path] else { return }
        var list = ours[keyPath: path]
        if server[keyPath: path] != base[keyPath: path] {
            for index in list.indices { list[index].origin = nil }
        }
        result[keyPath: path] = list
    }

    /// The card with REV set to `date` (replacing any REV it had).
    static func revised(_ card: VCard, at date: Date) -> VCard {
        var card = card
        let stamp = date.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted))
        let place = card.properties.firstIndex { $0.name == "REV" } ?? card.properties.endIndex
        card.properties.removeAll { $0.name == "REV" }
        card.properties.insert(VCardProperty(name: "REV", value: stamp), at: min(place, card.properties.endIndex))
        return card
    }
}

/// A list entry that remembers where in a card it was read from.
protocol OriginEntry: Equatable {
    var origin: Int? { get set }
}

extension LabeledValue: OriginEntry {}
extension VCardAddress: OriginEntry {}
