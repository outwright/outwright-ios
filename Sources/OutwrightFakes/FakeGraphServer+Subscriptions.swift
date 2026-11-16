// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The change-notification half of `FakeGraphServer` (`/subscriptions`), as Graph behaves: a
/// create first posts `?validationToken=` to the notification and lifecycle URLs and is 400 unless
/// both echo it; a second subscription on the same resource and change type is 409; the expiry is at
/// most 10,080 minutes away.
/// A subscription as the fake holds it (the fakes do not depend on `OutwrightGraph`).
public struct FakeGraphSubscription: Sendable, Equatable {
    public let id: String
    public let resource: String
    public let changeType: String
    public let notificationURL: URL
    public let expires: Date
}

struct FakeGraphSubscriptions {
    struct Held {
        var subscription: FakeGraphSubscription
        var lifecycleURL: URL
        var clientState: String
    }

    var held: [Held] = []
    var counter = 0
    var refuseWith: Int?
    var hiddenListings = 0
}

extension FakeGraphServer {
    /// The subscriptions held, oldest first.
    public var subscriptions: [FakeGraphSubscription] {
        subscriptionState.held.map(\.subscription)
    }

    /// Creates answer this status from now on (nil: normal service), as Graph does without consent.
    public func refuseSubscriptions(with status: Int?) {
        subscriptionState.refuseWith = status
    }

    /// The next listing answers empty, as when another device's create lands right after it.
    public func hideFromNextListing() {
        subscriptionState.hiddenListings += 1
    }

    /// Forgets every subscription, as when Microsoft removes them or they lapse.
    public func dropSubscriptions() {
        subscriptionState.held.removeAll()
    }

    /// Posts a change notification for a new message to every subscription's URL.
    public func deliverNewMail() async {
        for held in subscriptionState.held {
            let value: [String: Any] = [
                "subscriptionId": held.subscription.id, "clientState": held.clientState, "changeType": "created",
                "resource": "Users/00000000-0000-0000-0000-000000000001/Messages/AAMk\(subscriptionState.counter)",
                "tenantId": "00000000-0000-0000-0000-000000000002"
            ]
            let body = (try? JSONSerialization.data(withJSONObject: ["value": [value]])) ?? Data()
            _ = await Self.post(held.subscription.notificationURL, body: body)
        }
    }

    func subscriptionRoute(_ request: FakeHTTPRequest) async -> FakeHTTPResponse {
        let parts = Self.split(request.path).0.dropFirst("/v1.0/".count).split(separator: "/").map(String.init)
        switch (request.method, parts.count) {
        case ("POST", 1): return await createSubscription(request)
        case ("GET", 1): return listSubscriptions(Self.split(request.path).1)
        case ("PATCH", 2): return renewSubscription(parts[1], request)
        case ("DELETE", 2):
            guard let index = subscriptionState.held.firstIndex(where: { $0.subscription.id == parts[1] }) else {
                return FakeHTTPResponse(status: 404)
            }
            subscriptionState.held.remove(at: index)
            return FakeHTTPResponse(status: 204)
        default: return FakeHTTPResponse(status: 404)
        }
    }

    private func createSubscription(_ request: FakeHTTPRequest) async -> FakeHTTPResponse {
        if let status = subscriptionState.refuseWith {
            return FakeHTTPResponse(status: status)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
            let resource = object["resource"] as? String, let changeType = object["changeType"] as? String,
            let url = (object["notificationUrl"] as? String).flatMap(URL.init(string:)),
            let lifecycle = (object["lifecycleNotificationUrl"] as? String).flatMap(URL.init(string:)),
            let state = object["clientState"] as? String, state.utf8.count <= 128,
            let expires = (object["expirationDateTime"] as? String).flatMap(Self.date),
            expires > Date(), expires.timeIntervalSinceNow <= 10_080 * 60
        else { return FakeHTTPResponse(status: 400) }
        if isTaken(resource, changeType) {
            return FakeHTTPResponse(status: 409)
        }
        let token = "Validation: Testing client application reachability for subscription Request-Id: \(UUID())"
        for target in [url, lifecycle] where !(await Self.validates(target, token: token)) {
            return FakeHTTPResponse(status: 400)
        }
        // Another create may have won while this one validated.
        if isTaken(resource, changeType) {
            return FakeHTTPResponse(status: 409)
        }
        subscriptionState.counter += 1
        let made = FakeGraphSubscription(
            id: "sub-\(subscriptionState.counter)", resource: resource, changeType: changeType, notificationURL: url,
            expires: expires)
        subscriptionState.held.append(.init(subscription: made, lifecycleURL: lifecycle, clientState: state))
        return Self.ok(Self.object(made), status: 201)
    }

    private func isTaken(_ resource: String, _ changeType: String) -> Bool {
        subscriptionState.held.contains {
            $0.subscription.resource == resource && $0.subscription.changeType == changeType
        }
    }

    private func listSubscriptions(_ query: [String: String]) -> FakeHTTPResponse {
        if subscriptionState.hiddenListings > 0 {
            subscriptionState.hiddenListings -= 1
            return Self.ok(["value": [Any]()])
        }
        let skip = Int(query["$skip"] ?? "") ?? 0
        let page = subscriptionState.held.dropFirst(skip).prefix(pageSize)
        var body: [String: Any] = ["value": page.map { Self.object($0.subscription) }]
        if skip + page.count < subscriptionState.held.count {
            body["@odata.nextLink"] = "http://127.0.0.1:\(port)/v1.0/subscriptions?$skip=\(skip + pageSize)"
        }
        return Self.ok(body)
    }

    private func renewSubscription(_ id: String, _ request: FakeHTTPRequest) -> FakeHTTPResponse {
        guard let index = subscriptionState.held.firstIndex(where: { $0.subscription.id == id }) else {
            return FakeHTTPResponse(status: 404)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
            let expires = (object["expirationDateTime"] as? String).flatMap(Self.date),
            expires > Date(), expires.timeIntervalSinceNow <= 10_080 * 60
        else { return FakeHTTPResponse(status: 400) }
        let old = subscriptionState.held[index].subscription
        let renewed = FakeGraphSubscription(
            id: old.id, resource: old.resource, changeType: old.changeType, notificationURL: old.notificationURL,
            expires: expires)
        subscriptionState.held[index].subscription = renewed
        return Self.ok(Self.object(renewed))
    }

    private static func object(_ made: FakeGraphSubscription) -> [String: Any] {
        [
            "id": made.id, "resource": made.resource, "changeType": made.changeType,
            "notificationUrl": made.notificationURL.absoluteString, "expirationDateTime": text(made.expires),
            "applicationId": "00000000-0000-0000-0000-000000000003"
        ]
    }

    /// Graph's form: seven fractional digits.
    private static func text(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        let whole = date.timeIntervalSince1970.rounded(.down)
        let fraction = Int(((date.timeIntervalSince1970 - whole) * 10_000_000).rounded(.down))
        let stamp = format.string(from: Date(timeIntervalSince1970: whole))
        return String(stamp.dropLast()) + "." + String(format: "%07d", fraction) + "Z"
    }

    private static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func validates(_ url: URL, token: String) async -> Bool {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "validationToken", value: token)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: ":", with: "%3A")
        guard let target = parts.url, let (status, body) = await post(target, body: Data(), type: "text/plain")
        else { return false }
        return status == 200 && body == Data(token.utf8)
    }

    private static func post(_ url: URL, body: Data, type: String = "application/json") async -> (Int, Data)? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse
        else { return nil }
        return (http.statusCode, data)
    }
}
