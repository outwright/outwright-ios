// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Routes a test adds to the fake relay, for push methods' own routes.
extension FakeRelay {
    /// Adds a route of the relay's that `answer` plays: `v1/{name}/…` without authentication,
    /// and `v1/subscriptions/{id}/{name}/…` for the device that owns subscription `id`. It sees the
    /// call and says what the relay answers and which subscriptions get a content-free push.
    public func addRoute(_ name: String, _ answer: @escaping FakeRelayRoute) {
        routes[name] = answer
    }

    func routed(
        _ name: String, _ request: FakeHTTPRequest, path: [String], query: [String: String], subscription: String?
    ) -> FakeHTTPResponse? {
        guard let route = routes[name] else {
            return nil
        }
        let (response, woken) = route(FakeRelayCall(
            method: request.method, path: path, query: query, body: request.body, subscription: subscription,
            subscriptions: subscriptions, active: active))
        wakes += woken.filter { active.contains($0) }
        return response
    }

    static func split(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard let key = halves.first?.removingPercentEncoding else { continue }
                query[key] = halves.count > 1 ? (halves[1].removingPercentEncoding ?? "") : ""
            }
        }
        return (pieces.first.map(String.init) ?? "", query)
    }
}

/// A route a test added to the fake relay: the answer, and the subscriptions sent a push (only
/// active ones are).
public typealias FakeRelayRoute = @Sendable (FakeRelayCall) -> (FakeHTTPResponse, wakes: [String])

/// A call to a route a test added, as the route sees it.
public struct FakeRelayCall: Sendable {
    public let method: String
    /// The path after the route's name, split, without the query.
    public let path: [String]
    public let query: [String: String]
    public let body: Data
    /// For `subscriptions/{id}/{name}/…`: the caller's own subscription id.
    public let subscription: String?
    /// Every subscription the relay knows, and those that are active.
    public let subscriptions: Set<String>
    public let active: Set<String>
}
