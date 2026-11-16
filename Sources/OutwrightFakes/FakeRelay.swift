// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The push relay in memory, on 127.0.0.1. Accepts any non-empty
/// attestation and assertion; keeps the protocol's rules (single-use challenges, bearer
/// secrets, ten subscriptions per device, pending bodies until activation).
public actor FakeRelay {
    private var server: FakeHTTPServer?
    private var port: UInt16 = 0
    private var challenges: Set<String> = []
    private var devices: [String: String] = [:]
    private var owner: [String: String] = [:]
    private var counter = 0
    /// The pending (encrypted) bodies, by subscription id.
    public private(set) var held: [String: Data] = [:]
    /// Every subscription id the relay knows.
    public private(set) var subscriptions: Set<String> = []
    private(set) var active: Set<String> = []
    private var forced: FakeHTTPResponse?
    private var refusals: [FakeHTTPResponse] = []
    private var routeRefusals: [String: FakeHTTPResponse] = [:]
    private var pushRoutes: [String: @Sendable (FakeRelayPush) -> (FakeHTTPResponse, FakeRelayPush.Effect)] = [:]
    var routes: [String: FakeRelayRoute] = [:]
    /// Each device's current APNs token (hex), by device id.
    public private(set) var tokens: [String: String] = [:]
    /// The subscription of every content-free push sent to APNs, in order.
    public internal(set) var wakes: [String] = []
    /// The App Attest key id of every device registration, in order.
    public private(set) var registeredKeys: [String] = []
    /// How many requests have reached the relay.
    public private(set) var requestCount = 0

    public init() {}

    /// Starts serving; returns the base URL a `RelayClient` takes.
    public func start() async throws -> URL {
        let server = FakeHTTPServer { [weak self] request in
            await self?.handle(request) ?? FakeHTTPResponse(status: 500)
        }
        self.server = server
        port = try await server.start()
        return baseURL
    }

    public func stop() {
        server?.stop()
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1") ?? URL(fileURLWithPath: "/")
    }

    /// Delivers a body the way the mail server's push POST does: held until activation, after
    /// that a content-free push.
    public func push(_ body: Data, to subscriptionID: String) {
        guard subscriptions.contains(subscriptionID) else {
            return
        }
        guard !active.contains(subscriptionID) else {
            wakes.append(subscriptionID)
            return
        }
        held[subscriptionID] = body
    }

    /// `push/{id}` (Stalwart, encrypted) and `push/{id}/{route}` for a route a test added.
    private func pushRoute(_ body: Data, _ rest: [String]) -> FakeHTTPResponse {
        switch rest.count {
        case 2:
            guard let route = pushRoutes[rest[1]] else {
                return Self.fail(404, "notfound")
            }
            return served(route, body, to: rest[0])
        case 1:
            guard subscriptions.contains(rest[0]) else {
                return Self.fail(404, "notfound")
            }
            push(body, to: rest[0])
            return FakeHTTPResponse(status: 201)
        default:
            return Self.fail(404, "notfound")
        }
    }

    /// Adds `push/{id}/{name}`, a push route of the relay's that `answer` plays: it sees the body
    /// and the subscription, and says what the relay answers and does.
    public func addPushRoute(
        _ name: String, _ answer: @escaping @Sendable (FakeRelayPush) -> (FakeHTTPResponse, FakeRelayPush.Effect)
    ) {
        pushRoutes[name] = answer
    }

    private func served(
        _ route: @Sendable (FakeRelayPush) -> (FakeHTTPResponse, FakeRelayPush.Effect), _ body: Data, to id: String
    ) -> FakeHTTPResponse {
        guard subscriptions.contains(id) else {
            return Self.fail(404, "notfound")
        }
        let (response, effect) = route(FakeRelayPush(body: body, active: active.contains(id), held: held[id]))
        switch effect {
        case let .hold(body):
            held[id] = body
        case .wake:
            wakes.append(id)
        case .none:
            break
        }
        return response
    }

    /// Answers every request with this response (nil: back to normal).
    public func force(_ response: FakeHTTPResponse?) {
        forced = response
    }

    /// Answers the next `count` requests with this response, then serves normally again.
    public func refuseNext(_ count: Int, with response: FakeHTTPResponse) {
        refusals = Array(repeating: response, count: max(0, count))
    }

    /// Answers every request to one route, such as `POST devices` or `POST subscriptions`, with
    /// this response (nil: serves that route normally again).
    public func refuse(_ method: String, _ route: String, with response: FakeHTTPResponse?) {
        routeRefusals["\(method) \(route)"] = response
    }

    /// How many `refuseNext` answers are still to come.
    public var refusalsLeft: Int { refusals.count }

    /// Forgets every device and its subscriptions, as the relay does after APNs refuses a token.
    public func forgetDevices() {
        for sub in Array(owner.keys) {
            drop(sub)
        }
        devices = [:]
        tokens = [:]
    }

    /// Forgets one subscription, as a relay restored from an older backup does.
    public func forgetSubscription(_ id: String) {
        drop(id)
    }

    /// Whether a body the mail server sends to the subscription now would go to APNs.
    public func isActive(_ id: String) -> Bool {
        active.contains(id)
    }

    // MARK: - Routes

    private func handle(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        requestCount += 1
        if let forced {
            return forced
        }
        if !refusals.isEmpty {
            return refusals.removeFirst()
        }
        let (target, query) = Self.split(request.path)
        let path = target.split(separator: "/").map(String.init)
        guard path.count >= 2, path[0] == "v1" else {
            return Self.fail(404, "notfound")
        }
        if !["challenge", "devices", "subscriptions", "push"].contains(path[1]),
            let answer = routed(path[1], request, path: Array(path.dropFirst(2)), query: query, subscription: nil) {
            return answer
        }
        if let refused = routeRefusals["\(request.method) \(path.dropFirst().joined(separator: "/"))"] {
            return refused
        }
        switch (request.method, Array(path.dropFirst())) {
        case ("GET", ["challenge"]):
            counter += 1
            let value = "challenge-\(counter)"
            challenges.insert(value)
            return .json(200, "{\"challenge\":\"\(value)\"}")
        case ("POST", ["devices"]):
            return register(request)
        case ("POST", ["subscriptions"]):
            return subscribe(request)
        case ("POST", let parts) where parts.first == "push":
            return pushRoute(request.body, Array(parts.dropFirst()))
        default:
            return other(request, Array(path.dropFirst()))
        }
    }

    private func register(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        guard let body = Self.object(request.body), let challenge = body["challenge"] as? String,
            let attestation = body["attestation"] as? String, !attestation.isEmpty,
            let token = body["token"] as? String, !token.isEmpty, let keyID = body["keyId"] as? String,
            ["production", "development"].contains(body["environment"] as? String),
            challenges.remove(challenge) != nil
        else {
            return Self.fail(400, "bad")
        }
        registeredKeys.append(keyID)
        counter += 1
        let id = "device\(counter)", secret = "secret\(counter)"
        devices[id] = secret
        tokens[id] = token
        return .json(201, "{\"deviceId\":\"\(id)\",\"deviceSecret\":\"\(secret)\"}")
    }

    private func subscribe(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        guard let device = authorised(request) else {
            return Self.fail(401, "auth")
        }
        guard let body = Self.object(request.body), let challenge = body["challenge"] as? String,
            let assertion = body["assertion"] as? String, !assertion.isEmpty, challenges.remove(challenge) != nil
        else {
            return Self.fail(400, "bad")
        }
        if owner.values.filter({ $0 == device }).count >= 10 {
            return Self.fail(409, "limit")
        }
        counter += 1
        let id = "sub\(counter)"
        owner[id] = device
        subscriptions.insert(id)
        return .json(201, "{\"subscriptionId\":\"\(id)\",\"pushURL\":\"\(baseURL.absoluteString)/push/\(id)\"}")
    }

    private func other(_ request: FakeHTTPRequest, _ path: [String]) -> FakeHTTPResponse {
        guard let device = authorised(request) else {
            return Self.fail(401, "auth")
        }
        switch (request.method, path) {
        case ("PUT", let parts) where parts.count == 3 && parts[0] == "devices" && parts[2] == "token":
            guard parts[1] == device, let token = Self.object(request.body)?["token"] as? String, !token.isEmpty else {
                return Self.fail(404, "notfound")
            }
            tokens[device] = token
            return FakeHTTPResponse(status: 204)
        case ("DELETE", let parts) where parts.count == 2 && parts[0] == "devices":
            guard parts[1] == device else {
                return Self.fail(404, "notfound")
            }
            devices[device] = nil
            tokens[device] = nil
            for (sub, who) in owner where who == device {
                drop(sub)
            }
            return FakeHTTPResponse(status: 204)
        case (_, let parts) where parts.count >= 2 && parts[0] == "subscriptions":
            guard owner[parts[1]] == device else {
                return Self.fail(404, "notfound")
            }
            if parts.count >= 3, let answer = routed(
                parts[2], request, path: Array(parts.dropFirst(3)), query: [:], subscription: parts[1]) {
                return answer
            }
            return subscription(request.method, parts[1], Array(parts.dropFirst(2)))
        default:
            return Self.fail(404, "notfound")
        }
    }

    private func subscription(_ method: String, _ id: String, _ rest: [String]) -> FakeHTTPResponse {
        switch (method, rest) {
        case ("GET", ["pending"]):
            guard let body = held[id] else {
                return FakeHTTPResponse(status: 204)
            }
            return .json(200, "{\"body\":\"\(body.base64EncodedString())\"}")
        case ("POST", ["activate"]):
            held[id] = nil
            active.insert(id)
            return FakeHTTPResponse(status: 204)
        case ("DELETE", []):
            drop(id)
            return FakeHTTPResponse(status: 204)
        default:
            return Self.fail(404, "notfound")
        }
    }

    private func drop(_ id: String) {
        owner[id] = nil
        held[id] = nil
        active.remove(id)
        subscriptions.remove(id)
    }

    private func authorised(_ request: FakeHTTPRequest) -> String? {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else {
            return nil
        }
        let secret = String(header.dropFirst(7))
        return devices.first { $0.value == secret }?.key
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fail(_ status: Int, _ code: String) -> FakeHTTPResponse {
        .json(status, "{\"error\":\"\(code)\"}")
    }
}

/// A post to a push route a test added, as the route sees it.
public struct FakeRelayPush: Sendable {
    /// What the relay does besides answering.
    public enum Effect: Sendable {
        /// Holds this as the subscription's pending body.
        case hold(Data)
        /// Sends a content-free push.
        case wake
        case none
    }

    public let body: Data
    public let active: Bool
    /// The subscription's pending body, if any.
    public let held: Data?
}
