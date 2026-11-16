// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The Microsoft Graph contact and calendar calls Outwright makes (calendars: `+Calendars`), on
/// 127.0.0.1 for tests. The base URL to
/// give the client is `http://127.0.0.1:port/v1.0/`. The default Contacts folder is `me`; other
/// folders are `me/contactFolders/<id>`. ETags are `W/"<n>"`, bumped on every write; a write
/// with a stale `If-Match` answers 412.
public actor FakeGraphServer {
    struct Stored {
        var folder: String?
        var json: [String: any Sendable]
        var version: Int
    }

    private var server: FakeHTTPServer?
    private(set) var port: UInt16 = 0
    private var folders: [(id: String, name: String)] = []
    private var contacts: [(id: String, stored: Stored)] = []
    private var counter = 0
    private var failures: [Int] = []
    private var dropNextPost = false
    private var foreignNextLink: String?
    private var endless = false
    private var answerDelay: Duration?
    private var inFlight = 0
    /// The most requests that were being answered at the same time.
    public private(set) var mostAtOnce = 0
    var calendarState = FakeGraphCalendars()
    var subscriptionState = FakeGraphSubscriptions()
    /// Contacts per listing page.
    public var pageSize = 500
    /// When set, only these bearer tokens are accepted; others get 401.
    public var acceptedTokens: Set<String>?
    /// Every request received, oldest first.
    public private(set) var requests: [FakeHTTPRequest] = []

    public init() {}

    public func start() async throws -> URL {
        let server = FakeHTTPServer { [weak self] request in
            await self?.serve(request) ?? FakeHTTPResponse(status: 500)
        }
        self.server = server
        port = try await server.start()
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1.0/") else {
            throw FakeError.cannotListen("graph")
        }
        return url
    }

    public func stop() {
        server?.stop()
    }

    // MARK: - Controls

    /// A contact folder under the default one; its path for the client is `me/contactFolders/<id>`.
    @discardableResult
    public func addFolder(_ name: String) -> String {
        counter += 1
        let id = "folder-\(counter)"
        folders.append((id, name))
        return id
    }

    /// Stores a contact (a Graph JSON object without `id`) in a folder (nil: the default one).
    @discardableResult
    public func put(_ json: Data, in folder: String? = nil) -> String {
        counter += 1
        let id = "contact-\(counter)"
        let object = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
        contacts.append((id, Stored(folder: folder, json: Self.sendable(object), version: 1)))
        return id
    }

    /// The JSON of the contacts in a folder (nil: the default one), as the client would read them.
    public func contactsJSON(in folder: String? = nil) -> [Data] {
        contacts.filter { $0.stored.folder == folder }.map { Self.render($0.id, $0.stored) }
    }

    /// Changes a stored contact as another client would (its ETag moves).
    public func edit(_ id: String, _ key: String, _ value: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].stored.json[key] = value
        contacts[index].stored.version += 1
    }

    public func remove(_ id: String) {
        contacts.removeAll { $0.id == id }
    }

    /// The next requests answer these statuses, in order, before normal service.
    public func failNext(status: Int) {
        failures.append(status)
    }

    /// The next POST is carried out but its answer never arrives.
    public func dropAnswerOfNextPost() {
        dropNextPost = true
    }

    /// Listings point their next page at `host`.
    public func nextLinkTo(host: String) {
        foreignNextLink = host
    }

    /// Listings never end: every page has a next link.
    public func endlessPages() {
        endless = true
    }

    public func setPageSize(_ size: Int) {
        pageSize = size
    }

    public func setAcceptedTokens(_ tokens: Set<String>?) {
        acceptedTokens = tokens
    }

    /// Every answer waits this long first (a slow server), so requests overlap.
    public func delayAnswers(_ delay: Duration) {
        answerDelay = delay
    }

    // MARK: - Serving

    private func serve(_ request: FakeHTTPRequest) async -> FakeHTTPResponse {
        inFlight += 1
        mostAtOnce = max(mostAtOnce, inFlight)
        if let answerDelay {
            try? await Task.sleep(for: answerDelay)
        }
        inFlight -= 1
        requests.append(request)
        if let refused = gate(request) {
            return refused
        }
        if Self.split(request.path).0.hasPrefix("/v1.0/subscriptions") {
            return await subscriptionRoute(request)
        }
        return handle(request)
    }

    /// The answer for a refused token or a queued failure, if any.
    private func gate(_ request: FakeHTTPRequest) -> FakeHTTPResponse? {
        if let accepted = acceptedTokens {
            let token = request.headers["authorization"].map { String($0.dropFirst("Bearer ".count)) } ?? ""
            guard accepted.contains(token) else { return FakeHTTPResponse(status: 401) }
        }
        if !failures.isEmpty {
            return FakeHTTPResponse(status: failures.removeFirst())
        }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        let (path, query) = Self.split(request.path)
        guard path.hasPrefix("/v1.0/") else { return FakeHTTPResponse(status: 404) }
        let parts = path.dropFirst("/v1.0/".count).split(separator: "/").map(String.init)
        if let answer = calendarState.handle(request, parts, query, port: port, dropPost: &dropNextPost) {
            return answer
        }
        switch (request.method, parts.count) {
        case ("GET", 2) where parts == ["me", "contactFolders"]:
            return Self.ok(["value": folders.map { ["id": $0.id, "displayName": $0.name] }])
        case ("GET", 2) where parts == ["me", "contacts"]:
            return list(folder: nil, query)
        case ("GET", 4) where parts[1] == "contactFolders" && parts[3] == "contacts":
            return list(folder: parts[2], query)
        case ("POST", 2) where parts == ["me", "contacts"]:
            return create(request, folder: nil)
        case ("POST", 4) where parts[1] == "contactFolders" && parts[3] == "contacts":
            return create(request, folder: parts[2])
        case ("GET", 3) where parts[1] == "contacts":
            guard let found = contacts.first(where: { $0.id == parts[2] }) else { return FakeHTTPResponse(status: 404) }
            return FakeHTTPResponse(status: 200, body: Self.render(found.id, found.stored))
        case ("PATCH", 3) where parts[1] == "contacts":
            return update(request, id: parts[2])
        case ("DELETE", 3) where parts[1] == "contacts":
            guard let index = contacts.firstIndex(where: { $0.id == parts[2] }) else {
                return FakeHTTPResponse(status: 404)
            }
            if let match = request.headers["if-match"], match != Self.etag(contacts[index].stored) {
                return FakeHTTPResponse(status: 412)
            }
            contacts.remove(at: index)
            return FakeHTTPResponse(status: 204)
        default:
            return FakeHTTPResponse(status: 404)
        }
    }

    private func list(folder: String?, _ query: [String: String]) -> FakeHTTPResponse {
        if folder != nil, !folders.contains(where: { $0.id == folder }) {
            return FakeHTTPResponse(status: 404)
        }
        var held = contacts.filter { $0.stored.folder == folder }
        if let filter = query["$filter"] {
            // Only the create-marker lookup is understood: `... ep/value eq '<value>')`.
            let value = filter.components(separatedBy: "ep/value eq '").last?.components(separatedBy: "'").first ?? ""
            held = held.filter { Self.marker(of: $0.stored) == value }
        }
        let skip = Int(query["$skip"] ?? "") ?? 0
        let page = Array(held.dropFirst(skip).prefix(pageSize))
        var body: [String: Any] = ["value": page.map { Self.object($0.id, $0.stored) }]
        let more = skip + page.count < held.count
        if let host = foreignNextLink {
            body["@odata.nextLink"] = "http://\(host)/v1.0/me/contacts?$skip=\(skip + pageSize)"
        } else if more || endless {
            let base = folder.map { "me/contactFolders/\($0)/contacts" } ?? "me/contacts"
            body["@odata.nextLink"] = "http://127.0.0.1:\(port)/v1.0/\(base)?$skip=\(skip + pageSize)"
        }
        return Self.ok(body)
    }

    private func create(_ request: FakeHTTPRequest, folder: String?) -> FakeHTTPResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return FakeHTTPResponse(status: 400)
        }
        counter += 1
        let id = "contact-\(counter)"
        let stored = Stored(folder: folder, json: Self.sendable(object), version: 1)
        contacts.append((id, stored))
        if dropNextPost {
            dropNextPost = false
            return .dropped
        }
        return FakeHTTPResponse(status: 201, body: Self.render(id, stored))
    }

    private func update(_ request: FakeHTTPRequest, id: String) -> FakeHTTPResponse {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return FakeHTTPResponse(status: 404) }
        if let match = request.headers["if-match"], match != Self.etag(contacts[index].stored) {
            return FakeHTTPResponse(status: 412)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return FakeHTTPResponse(status: 400)
        }
        for (key, value) in Self.sendable(object) {
            contacts[index].stored.json[key] = value
        }
        contacts[index].stored.version += 1
        return FakeHTTPResponse(status: 200, body: Self.render(id, contacts[index].stored))
    }

    // MARK: - JSON

    private static func etag(_ stored: Stored) -> String {
        #"W/"\#(stored.version)""#
    }

    private static func marker(of stored: Stored) -> String? {
        let properties = stored.json["singleValueExtendedProperties"] as? [[String: any Sendable]]
        return properties?.first?["value"] as? String
    }

    private static func object(_ id: String, _ stored: Stored) -> [String: Any] {
        var object: [String: Any] = stored.json
        object.removeValue(forKey: "singleValueExtendedProperties")
        object["id"] = id
        object["@odata.etag"] = etag(stored)
        return object
    }

    private static func render(_ id: String, _ stored: Stored) -> Data {
        (try? JSONSerialization.data(withJSONObject: object(id, stored))) ?? Data()
    }

    static func ok(_ body: [String: Any], status: Int = 200) -> FakeHTTPResponse {
        FakeHTTPResponse(
            status: status, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(),
            headers: ["Content-Type": "application/json"])
    }

    /// JSON as values that may cross into the actor's storage.
    static func sendable(_ object: [String: Any]) -> [String: any Sendable] {
        object.compactMapValues(sendableValue)
    }

    private static func sendableValue(_ value: Any) -> (any Sendable)? {
        switch value {
        case let text as String: text
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number.doubleValue
        case let array as [Any]: array.compactMap(sendableValue)
        case let object as [String: Any]: sendable(object)
        default: nil
        }
    }

    static func split(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1)
        let path = pieces.first.map(String.init) ?? ""
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard let key = halves.first?.removingPercentEncoding else { continue }
                query[key] = halves.count > 1 ? (halves[1].removingPercentEncoding ?? "") : ""
            }
        }
        return (path, query)
    }
}
