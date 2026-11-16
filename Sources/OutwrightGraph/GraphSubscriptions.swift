// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A Graph change-notification subscription (`/subscriptions`), as Graph reports it.
public struct GraphSubscription: Sendable, Equatable {
    public let id: String
    public let resource: String
    public let changeType: String
    public let notificationURL: URL
    public let expires: Date

    public init(id: String, resource: String, changeType: String, notificationURL: URL, expires: Date) {
        self.id = id
        self.resource = resource
        self.changeType = changeType
        self.notificationURL = notificationURL
        self.expires = expires
    }
}

/// What a new subscription watches and where Graph posts.
public struct GraphSubscriptionRequest: Sendable, Equatable {
    public let resource: String
    public let changeType: String
    public let notificationURL: URL
    public let lifecycleURL: URL
    /// Echoed in every notification; at most 128 characters.
    public let clientState: String

    public init(resource: String, changeType: String, notificationURL: URL, lifecycleURL: URL, clientState: String) {
        self.resource = resource
        self.changeType = changeType
        self.notificationURL = notificationURL
        self.lifecycleURL = lifecycleURL
        self.clientState = clientState
    }
}

extension GraphClient {
    /// Subscribes `request.resource` for `request.changeType` until `expires`. Graph first posts a
    /// validation token to the notification and lifecycle URLs, which must echo it; a subscription
    /// of this app on the same resource and change type already there is `.conflict`.
    public func createSubscription(
        _ request: GraphSubscriptionRequest, expires: Date
    ) async throws(GraphError) -> GraphSubscription {
        guard GraphSubscriptions.isReachable(request.notificationURL),
            GraphSubscriptions.isReachable(request.lifecycleURL),
            request.clientState.utf8.count <= GraphSubscriptions.maxClientState
        else { throw .malformed }
        let body: [String: String] = [
            "changeType": request.changeType, "notificationUrl": request.notificationURL.absoluteString,
            "lifecycleNotificationUrl": request.lifecycleURL.absoluteString, "resource": request.resource,
            "expirationDateTime": GraphSubscriptions.text(expires), "clientState": request.clientState
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw .malformed }
        return try GraphSubscriptions.subscription(try await send("POST", url("subscriptions"), body: data))
    }

    /// Every subscription this app holds for the signed-in user.
    public func subscriptions() async throws(GraphError) -> [GraphSubscription] {
        var found: [GraphSubscription] = []
        for page in try await pages(url("subscriptions")) {
            found += try GraphSubscriptions.page(page)
        }
        return found
    }

    /// Moves a subscription's expiry; the expiry Graph set comes back. `.notFound` when it is gone.
    public func renewSubscription(_ id: String, expires: Date) async throws(GraphError) -> Date {
        let body = ["expirationDateTime": GraphSubscriptions.text(expires)]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw .malformed }
        let answer = try await send("PATCH", url("subscriptions/" + GraphContacts.segment(id)), body: data)
        return try GraphSubscriptions.subscription(answer).expires
    }

    /// Deletes a subscription. `.notFound` when it is gone.
    public func deleteSubscription(_ id: String) async throws(GraphError) {
        _ = try await send("DELETE", url("subscriptions/" + GraphContacts.segment(id)))
    }
}

enum GraphSubscriptions {
    /// Graph's cap on `clientState`.
    static let maxClientState = 128
    static let maxField = 2048

    /// https, or plain http to loopback (tests).
    static func isReachable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host()?.isEmpty == false
        case "http": Loopback.hosts.contains(url.host()?.lowercased() ?? "")
        default: false
        }
    }

    static func text(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    /// An ISO 8601 UTC time with any number of fractional digits (Graph sends seven).
    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        guard let dot = text.firstIndex(of: ".") else { return format.date(from: text) }
        let rest = text[text.index(after: dot)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let zone = String(rest.dropFirst(digits.count))
        guard !digits.isEmpty, let whole = format.date(from: String(text[..<dot]) + zone),
            let fraction = Double("0." + digits.prefix(9))
        else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    static func page(_ data: Data) throws(GraphError) -> [GraphSubscription] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = object["value"] as? [Any]
        else { throw .malformed }
        return entries.compactMap { ($0 as? [String: Any]).flatMap(subscription) }
    }

    static func subscription(_ data: Data) throws(GraphError) -> GraphSubscription {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let found = subscription(object)
        else { throw .malformed }
        return found
    }

    private static func subscription(_ object: [String: Any]) -> GraphSubscription? {
        func field(_ key: String) -> String? {
            guard let text = object[key] as? String, !text.isEmpty, text.utf8.count <= maxField else { return nil }
            return text
        }
        guard let id = field("id"), let resource = field("resource"), let changeType = field("changeType"),
            let url = field("notificationUrl").flatMap({ URL(string: $0) }), isReachable(url),
            let expires = field("expirationDateTime").flatMap(date)
        else { return nil }
        return GraphSubscription(
            id: id, resource: resource, changeType: changeType, notificationURL: url, expires: expires)
    }
}
