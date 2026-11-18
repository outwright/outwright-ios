// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Contact photos, kept apart from the contacts as Graph keeps them: `me/contacts/<id>/photo/$value`.
extension FakeGraphServer {
    /// Gives a contact a photo, as Outlook would.
    public func setPhoto(_ id: String, _ data: Data) {
        photos[id] = data
    }

    /// The next photo uploads answer these statuses, in order, before normal service.
    public func failNextPhoto(status: Int) {
        photoFailures.append(status)
    }

    /// Right after the next photo upload, another client changes the contact's `key`.
    public func editAfterNextPhoto(_ key: String, _ value: String) {
        editAfterPhoto = (key, value)
    }

    /// The contact read right after the next photo upload comes back as no contact.
    public func malformNextReadAfterPhoto() {
        malformedRead.afterPhoto = true
    }

    /// The contact's photo, nil when it has none.
    public func photo(of id: String) -> Data? {
        photos[id]
    }

    /// The answer to a photo request; nil for any other.
    func photoRoute(_ request: FakeHTTPRequest, _ parts: [String]) -> FakeHTTPResponse? {
        if malformedRead.pending, request.method == "GET", parts.count == 3, parts[1] == "contacts" {
            malformedRead.pending = false
            return FakeHTTPResponse(status: 200, body: Data("{}".utf8))
        }
        guard parts.count == 5, parts[0] == "me", parts[1] == "contacts", parts[3] == "photo", parts[4] == "$value"
        else { return nil }
        let id = parts[2]
        switch request.method {
        case "GET":
            guard let photo = photos[id] else { return FakeHTTPResponse(status: 404) }
            return FakeHTTPResponse(status: 200, body: photo, headers: ["Content-Type": "image/jpeg"])
        case "PUT":
            if !photoFailures.isEmpty { return FakeHTTPResponse(status: photoFailures.removeFirst()) }
            guard let index = contacts.firstIndex(where: { $0.id == id }) else { return FakeHTTPResponse(status: 404) }
            photos[id] = request.body
            // Graph moves the contact's ETag with its photo.
            contacts[index].stored.version += 1
            if let (key, value) = editAfterPhoto {
                editAfterPhoto = nil
                contacts[index].stored.json[key] = value
                contacts[index].stored.version += 1
            }
            if malformedRead.afterPhoto {
                malformedRead = (afterPhoto: false, pending: true)
            }
            return FakeHTTPResponse(status: 200)
        default:
            return FakeHTTPResponse(status: 405)
        }
    }
}
