// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A contact folder: the default Contacts folder (`path` "me") or one of its children
/// (`me/contactFolders/<id>`). Its contacts are at `<path>/contacts`.
public struct GraphFolder: Sendable, Equatable, Hashable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    public static let defaultFolder = GraphFolder(path: "me", name: "Contacts")
}

public struct GraphAddress: Sendable, Equatable {
    public var street: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var countryOrRegion: String

    public init(
        street: String = "", city: String = "", state: String = "", postalCode: String = "",
        countryOrRegion: String = ""
    ) {
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.countryOrRegion = countryOrRegion
    }

    var isEmpty: Bool {
        [street, city, state, postalCode, countryOrRegion].allSatisfy(\.isEmpty)
    }
}

/// The properties of a Graph contact Outwright shows and edits. Nothing else is ever written.
public struct GraphContactFields: Sendable, Equatable {
    public var givenName: String
    public var surname: String
    public var displayName: String
    public var companyName: String
    public var jobTitle: String
    public var personalNotes: String
    /// At most three: what Graph holds.
    public var emails: [String]
    /// Graph's name for an address (Outlook shows it), by the address lower-cased. Not shown or
    /// edited here; written back with the address it belongs to.
    public var emailNames: [String: String] = [:]
    public var mobilePhone: String
    public var businessPhones: [String]
    public var homePhones: [String]
    public var home: GraphAddress?
    public var business: GraphAddress?
    public var other: GraphAddress?

    public init(
        givenName: String = "", surname: String = "", displayName: String = "", companyName: String = "",
        jobTitle: String = "", personalNotes: String = "", emails: [String] = [], mobilePhone: String = "",
        businessPhones: [String] = [],
        homePhones: [String] = [], home: GraphAddress? = nil, business: GraphAddress? = nil,
        other: GraphAddress? = nil
    ) {
        self.givenName = givenName
        self.surname = surname
        self.displayName = displayName
        self.companyName = companyName
        self.jobTitle = jobTitle
        self.personalNotes = personalNotes
        self.emails = emails
        self.mobilePhone = mobilePhone
        self.businessPhones = businessPhones
        self.homePhones = homePhones
        self.home = home
        self.business = business
        self.other = other
    }
}

/// A contact as Graph has it: its id, ETag, the JSON as it came, and the mapped fields.
public struct GraphContact: Sendable, Equatable {
    public let id: String
    public let etag: String
    public let json: Data
    public let fields: GraphContactFields
}

/// Reading and writing Graph contact JSON. Everything read is hostile: a property of the wrong
/// type reads as empty, strings are capped, lists are capped.
public enum GraphContacts {
    /// The single-value extended property a create carries, so a create whose answer was lost
    /// is found instead of made twice.
    public static let createMarkerID = "String {13650EE9-7D0A-4EF4-B1D7-CBC2351E215F} Name OutwrightCreateID"
    /// The properties Outwright writes (and selects when reading).
    public static let ownProperties: Set<String> = [
        "givenName", "surname", "displayName", "companyName", "jobTitle", "personalNotes", "emailAddresses",
        "mobilePhone",
        "businessPhones", "homePhones", "homeAddress", "businessAddress", "otherAddress"
    ]
    static let maxString = 64 * 1024
    /// A contact's photo is read only up to this size; a larger one is not shown.
    public static let maxPhotoBytes = 512 * 1024
    static let maxList = 50
    static let maxEmails = 3
    static let pageSize = 500

    static var select: String {
        (["id"] + ownProperties.sorted()).joined(separator: ",")
    }

    // MARK: Reading

    /// A listing page's contacts (entries without an id or ETag are skipped) and its next link.
    static func page(_ data: Data) throws(GraphError) -> (contacts: [GraphContact], next: URL?) {
        let object = try root(data)
        let entries = (object["value"] as? [Any]) ?? []
        return (entries.compactMap { ($0 as? [String: Any]).flatMap(contact) }, try link(object))
    }

    /// The next link of a listing page, nil on the last.
    static func nextLink(_ data: Data) throws(GraphError) -> URL? {
        try link(root(data))
    }

    /// The held note in full when the app holds it cut (past `maxString`): an edit that left the cut
    /// note alone writes this back, not the cut one. Nil when it was not cut.
    public static func fullNote(json data: Data, replacing note: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let full = object["personalNotes"] as? String, full.count > maxString,
            String(full.prefix(maxString)) == note
        else { return nil }
        return full
    }

    /// The fields of a contact's JSON as held (the store's server copy), nil when it is not one.
    public static func fields(json data: Data) -> GraphContactFields? {
        contact(data)?.fields
    }

    /// One contact's JSON, nil when it is not one.
    static func contact(_ data: Data) -> GraphContact? {
        (try? root(data)).flatMap(contact)
    }

    private static func root(_ data: Data) throws(GraphError) -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .malformed
        }
        return object
    }

    private static func link(_ object: [String: Any]) throws(GraphError) -> URL? {
        guard let text = object["@odata.nextLink"] else { return nil }
        guard let text = text as? String, let url = URL(string: text) else { throw .malformed }
        return url
    }

    private static func contact(_ object: [String: Any]) -> GraphContact? {
        guard let id = object["id"] as? String, !id.isEmpty, id.count <= 1024,
            let etag = object["@odata.etag"] as? String, !etag.isEmpty, etag.count <= 1024,
            let json = try? JSONSerialization.data(withJSONObject: object)
        else {
            return nil
        }
        return GraphContact(id: id, etag: etag, json: json, fields: fields(object))
    }

    static func fields(_ object: [String: Any]) -> GraphContactFields {
        let entries = ((object["emailAddresses"] as? [Any]) ?? []).prefix(maxList).compactMap { $0 as? [String: Any] }
        let emails = entries.compactMap { ($0["address"] as? String).map(capped) }.filter { !$0.isEmpty }
        var names: [String: String] = [:]
        for entry in entries {
            guard let address = entry["address"] as? String, let name = entry["name"] as? String, !name.isEmpty
            else { continue }
            names[capped(address).lowercased()] = capped(name)
        }
        var fields = GraphContactFields(
            givenName: string(object, "givenName"), surname: string(object, "surname"),
            displayName: string(object, "displayName"), companyName: string(object, "companyName"),
            jobTitle: string(object, "jobTitle"), personalNotes: string(object, "personalNotes"),
            emails: Array(emails.prefix(maxEmails)),
            mobilePhone: string(object, "mobilePhone"), businessPhones: strings(object, "businessPhones"),
            homePhones: strings(object, "homePhones"), home: address(object, "homeAddress"),
            business: address(object, "businessAddress"), other: address(object, "otherAddress"))
        fields.emailNames = names
        return fields
    }

    private static func capped(_ text: String) -> String {
        text.count > maxString ? String(text.prefix(maxString)) : text
    }

    private static func string(_ object: [String: Any], _ key: String) -> String {
        (object[key] as? String).map(capped) ?? ""
    }

    private static func strings(_ object: [String: Any], _ key: String) -> [String] {
        ((object[key] as? [Any]) ?? []).prefix(maxList).compactMap { ($0 as? String).map(capped) }
            .filter { !$0.isEmpty }
    }

    private static func address(_ object: [String: Any], _ key: String) -> GraphAddress? {
        guard let parts = object[key] as? [String: Any] else { return nil }
        let address = GraphAddress(
            street: string(parts, "street"), city: string(parts, "city"), state: string(parts, "state"),
            postalCode: string(parts, "postalCode"), countryOrRegion: string(parts, "countryOrRegion"))
        return address.isEmpty ? nil : address
    }

    // MARK: Writing

    /// The JSON of `fields`: every own property, an absent address as all empty.
    static func body(_ fields: GraphContactFields, createID: String? = nil) -> Data {
        func address(_ value: GraphAddress?) -> [String: String] {
            let value = value ?? GraphAddress()
            return [
                "street": value.street, "city": value.city, "state": value.state, "postalCode": value.postalCode,
                "countryOrRegion": value.countryOrRegion
            ]
        }
        var object: [String: Any] = [
            "givenName": fields.givenName, "surname": fields.surname, "displayName": fields.displayName,
            "companyName": fields.companyName, "jobTitle": fields.jobTitle, "personalNotes": fields.personalNotes,
            "emailAddresses": fields.emails.prefix(maxEmails).map { address in
                fields.emailNames[address.lowercased()].map { ["address": address, "name": $0] } ?? ["address": address]
            },
            "mobilePhone": fields.mobilePhone, "businessPhones": fields.businessPhones,
            "homePhones": fields.homePhones, "homeAddress": address(fields.home),
            "businessAddress": address(fields.business), "otherAddress": address(fields.other)
        ]
        if let createID {
            object["singleValueExtendedProperties"] = [["id": createMarkerID, "value": createID]]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A create id goes into a `$filter` literal: only a UUID's characters are allowed.
    static func isSafe(_ createID: String) -> Bool {
        !createID.isEmpty && createID.count <= 64
            && createID.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }
    }

    /// A Graph id as one path segment.
    static func segment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

extension GraphClient {
    /// The default Contacts folder first, then its child folders.
    public func folders() async throws(GraphError) -> [GraphFolder] {
        let first = try url(
            "me/contactFolders", query: [("$select", "id,displayName"), ("$top", "\(GraphContacts.pageSize)")])
        var folders = [GraphFolder.defaultFolder]
        for page in try await pages(first) {
            guard let object = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any] else {
                throw .malformed
            }
            for entry in (object["value"] as? [Any]) ?? [] {
                guard let entry = entry as? [String: Any], let id = entry["id"] as? String, !id.isEmpty,
                    id.count <= 1024
                else { continue }
                let name = (entry["displayName"] as? String).map { String($0.prefix(256)) } ?? ""
                folders.append(GraphFolder(path: "me/contactFolders/" + GraphContacts.segment(id), name: name))
            }
        }
        return folders
    }

    /// Every contact in `folder`.
    public func contacts(in folder: GraphFolder) async throws(GraphError) -> [GraphContact] {
        let query = [("$select", GraphContacts.select), ("$top", "\(GraphContacts.pageSize)")]
        let first = try url(folder.path + "/contacts", query: query)
        var contacts: [GraphContact] = []
        for page in try await pages(first) {
            contacts += try GraphContacts.page(page).contacts
        }
        return contacts
    }

    /// The contact with `id`, nil when Graph has none.
    public func contact(id: String) async throws(GraphError) -> GraphContact? {
        do throws(GraphError) {
            let data = try await send(
                "GET", url("me/contacts/" + GraphContacts.segment(id), query: [("$select", GraphContacts.select)]))
            guard let contact = GraphContacts.contact(data) else { throw GraphError.malformed }
            return contact
        } catch .notFound {
            return nil
        }
    }

    /// Creates a contact in `folder`, marked with `createID` (see `find`).
    public func create(
        _ fields: GraphContactFields, createID: String, in folder: GraphFolder
    ) async throws(GraphError) -> GraphContact {
        guard GraphContacts.isSafe(createID) else { throw .malformed }
        let data = try await send(
            "POST", url(folder.path + "/contacts"), body: GraphContacts.body(fields, createID: createID))
        guard let made = GraphContacts.contact(data) else { throw .malformed }
        return made
    }

    /// The contact in `folder` a create with `createID` made, nil when none did.
    public func find(createID: String, in folder: GraphFolder) async throws(GraphError) -> GraphContact? {
        guard GraphContacts.isSafe(createID) else { throw .malformed }
        let filter = "singleValueExtendedProperties/Any(ep: ep/id eq '\(GraphContacts.createMarkerID)' "
            + "and ep/value eq '\(createID)')"
        let data = try await send(
            "GET", url(folder.path + "/contacts", query: [("$filter", filter), ("$select", GraphContacts.select)]))
        return try GraphContacts.page(data).contacts.first
    }

    /// Writes `fields` over the contact, if its ETag is still `ifMatch`.
    public func update(
        id: String, _ fields: GraphContactFields, ifMatch: String
    ) async throws(GraphError) -> GraphContact {
        let target = try url("me/contacts/" + GraphContacts.segment(id))
        let data = try await send("PATCH", target, body: GraphContacts.body(fields), ifMatch: ifMatch)
        if let updated = GraphContacts.contact(data) {
            return updated
        }
        guard let fresh = try await contact(id: id) else { throw .notFound }
        return fresh
    }

    /// The contact's photo, nil when it has none or one past `GraphContacts.maxPhotoBytes`.
    public func photo(id: String) async throws(GraphError) -> Data? {
        do throws(GraphError) {
            let data = try await send(
                "GET", url("me/contacts/" + GraphContacts.segment(id) + "/photo/$value"), accept: "image/*",
                limit: GraphContacts.maxPhotoBytes)
            return data.isEmpty || data.count > GraphContacts.maxPhotoBytes ? nil : data
        } catch .notFound {
            return nil
        } catch .tooLarge {
            return nil
        }
    }

    /// Gives the contact `jpeg` as its photo.
    public func setPhoto(id: String, _ jpeg: Data) async throws(GraphError) {
        guard jpeg.count <= GraphContacts.maxPhotoBytes else { throw .tooLarge }
        _ = try await send(
            "PUT", url("me/contacts/" + GraphContacts.segment(id) + "/photo/$value"), body: jpeg,
            contentType: "image/jpeg")
    }

    /// Deletes the contact, if its ETag is still `ifMatch`; one already gone counts as deleted.
    public func delete(id: String, ifMatch: String?) async throws(GraphError) {
        do throws(GraphError) {
            _ = try await send("DELETE", url("me/contacts/" + GraphContacts.segment(id)), ifMatch: ifMatch)
        } catch .notFound {
            return
        }
    }
}
