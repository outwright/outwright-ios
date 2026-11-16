// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightGraph
public import OutwrightModel

/// Between a Graph contact's properties and what the app shows. Graph has no e-mail labels
/// (they read as `other`), one mobile number, and one home, work and other address; the editor
/// offers no more than that for a Graph account, so writing drops nothing it showed.
public enum GraphContactMapping {
    public static func details(_ fields: GraphContactFields) -> ContactDetails {
        var phones: [Labeled] = []
        if !fields.mobilePhone.isEmpty {
            phones.append(Labeled(label: "mobile", value: fields.mobilePhone))
        }
        phones += fields.businessPhones.map { Labeled(label: "work", value: $0) }
        phones += fields.homePhones.map { Labeled(label: "home", value: $0) }
        let addresses = [("home", fields.home), ("work", fields.business), ("other", fields.other)]
            .compactMap { label, address in address.map { postal(label, $0) } }
        return ContactDetails(
            givenName: fields.givenName, familyName: fields.surname, displayName: fields.displayName,
            organization: fields.companyName, note: fields.personalNotes,
            emails: fields.emails.map { Labeled(label: "other", value: $0) }, phones: phones, addresses: addresses)
    }

    /// The first mobile number is Graph's mobile; a further one, and any other label, is a work
    /// number. The first address of each label is kept; one of an unknown label is `other`.
    public static func fields(_ details: ContactDetails) -> GraphContactFields {
        var fields = GraphContactFields(
            givenName: details.givenName, surname: details.familyName, displayName: details.displayName,
            companyName: details.organization, personalNotes: details.note,
            emails: Array(details.emails.map(\.value).filter { !$0.isEmpty }.prefix(3)))
        for phone in details.phones where !phone.value.isEmpty {
            switch phone.label {
            case "mobile" where fields.mobilePhone.isEmpty, "cell" where fields.mobilePhone.isEmpty:
                fields.mobilePhone = phone.value
            case "home": fields.homePhones.append(phone.value)
            default: fields.businessPhones.append(phone.value)
            }
        }
        for address in details.addresses {
            let graph = GraphAddress(
                street: address.street, city: address.locality, state: address.region, postalCode: address.postalCode,
                countryOrRegion: address.country)
            switch address.label {
            case "home" where fields.home == nil: fields.home = graph
            case "work" where fields.business == nil: fields.business = graph
            case "home", "work": break
            default: if fields.other == nil { fields.other = graph }
            }
        }
        return fields
    }

    private static func postal(_ label: String, _ address: GraphAddress) -> PostalAddress {
        PostalAddress(
            label: label, street: address.street, locality: address.city, region: address.state,
            postalCode: address.postalCode, country: address.countryOrRegion)
    }
}
