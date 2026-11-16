// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel

/// What to do to bring the phone's copy of an account's contacts in step with them.
public enum PhoneExport {
    /// Every wanted contact is saved (over its phone contact, when it has one); a phone contact
    /// whose contact is no longer wanted is removed. Nothing else on the phone is named.
    public static func plan(
        exported: [ContactID: String], wanted: [Contact]
    ) -> (upsert: [(Contact, String?)], remove: [String]) {
        let wantedIDs = Set(wanted.map(\.id))
        let upsert = wanted.map { ($0, exported[$0.id]) }
        let remove = exported.filter { !wantedIDs.contains($0.key) }.map(\.value).sorted()
        return (upsert, remove)
    }

    /// The name a contact shows on the phone, as `SystemPhoneContacts` writes it: given and family
    /// name, else the organisation, else the contact's name.
    public static func phoneName(_ details: ContactDetails) -> String {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let person = [trim(details.givenName), trim(details.familyName)].filter { !$0.isEmpty }
        if !person.isEmpty { return person.joined(separator: " ") }
        return trim(details.organization).isEmpty ? details.name : trim(details.organization)
    }

    /// Members of a group found by name (Outwright's group from before a reinstall) that are taken as
    /// the copies of not yet exported contacts: same phone name and same first e-mail address (never
    /// empty), and not already recorded for any account (`taken`). Every other member is the
    /// owner's, or another account's, and is never named.
    public static func adopt(
        members: [PhoneMember], wanted: [Contact], exported: [ContactID: String], taken: Set<String>
    ) -> [ContactID: String] {
        let taken = taken.union(exported.values)
        var free = members.filter { !taken.contains($0.identifier) && !$0.email.isEmpty }
        var found: [ContactID: String] = [:]
        for contact in wanted where exported[contact.id] == nil {
            let name = phoneName(contact.details)
            let email = (contact.details.emails.first?.value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !email.isEmpty, let index = free.firstIndex(where: { $0.name == name && $0.email == email })
            else { continue }
            found[contact.id] = free[index].identifier
            free.remove(at: index)
        }
        return found
    }
}
