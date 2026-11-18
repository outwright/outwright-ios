// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A device the relay has registered. Kept only in the keychain.
public struct RelayDevice: Codable, Sendable {
    public var deviceID: String
    public var secret: String

    public init(deviceID: String, secret: String) {
        self.deviceID = deviceID
        self.secret = secret
    }
}

/// A relay subscription: its id and the URL the mail server pushes to.
public struct RelaySubscription: Codable, Sendable {
    public var id: String
    public var pushURL: URL

    public init(id: String, pushURL: URL) {
        self.id = id
        self.pushURL = pushURL
    }
}

/// Which APNs host the relay uses for the device.
public enum APNsEnvironment: String, Codable, Sendable {
    case production
    case development
}

/// The relay's HTTPS API. Answers are capped at 64 KiB; plain http is allowed only to loopback.
public actor RelayClient {
    static let maxResponse = 64 * 1024
    private let base: URL
    /// The relay's base URL (`…/v1`), which names it: a method checks addresses against it.
    public nonisolated var baseURL: URL { base }
    private let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func challenge() async throws(PushError) -> String {
        struct Answer: Decodable { let challenge: String }
        let (_, data) = try await send("GET", "challenge", expect: [200])
        return try decode(Answer.self, data).challenge
    }

    public func registerDevice(
        keyID: String, attestation: Data, challenge: String, token: Data, environment: APNsEnvironment
    ) async throws(PushError) -> RelayDevice {
        struct Body: Encodable {
            let keyId: String, attestation: String, challenge: String, token: String, environment: String
        }
        struct Answer: Decodable { let deviceId: String, deviceSecret: String }
        let body = Body(
            keyId: keyID, attestation: attestation.base64EncodedString(), challenge: challenge,
            token: Self.hex(token), environment: environment.rawValue)
        let (_, data) = try await send("POST", "devices", json: body, expect: [201])
        let answer = try decode(Answer.self, data)
        return RelayDevice(deviceID: answer.deviceId, secret: answer.deviceSecret)
    }

    public func updateToken(_ token: Data, device: RelayDevice) async throws(PushError) {
        struct Body: Encodable { let token: String }
        _ = try await send(
            "PUT", "devices/\(try segment(device.deviceID))/token", json: Body(token: Self.hex(token)),
            secret: device.secret, expect: [204])
    }

    public func removeDevice(_ device: RelayDevice) async throws(PushError) {
        _ = try await send("DELETE", "devices/\(try segment(device.deviceID))", secret: device.secret, expect: [204])
    }

    public func subscribe(
        challenge: String, assertion: Data, device: RelayDevice
    ) async throws(PushError) -> RelaySubscription {
        struct Body: Encodable { let challenge: String, assertion: String }
        struct Answer: Decodable { let subscriptionId: String, pushURL: String }
        let (_, data) = try await send(
            "POST", "subscriptions", json: Body(challenge: challenge, assertion: assertion.base64EncodedString()),
            secret: device.secret, expect: [201])
        let answer = try decode(Answer.self, data)
        guard let url = URL(string: answer.pushURL), url.scheme == "https" || Self.isLoopback(url) else {
            throw .malformed
        }
        return RelaySubscription(id: answer.subscriptionId, pushURL: url)
    }

    public func pendingBody(_ sub: RelaySubscription, device: RelayDevice) async throws(PushError) -> Data? {
        struct Answer: Decodable { let body: String }
        let (status, data) = try await send(
            "GET", "subscriptions/\(try segment(sub.id))/pending", secret: device.secret, expect: [200, 204])
        if status == 204 {
            return nil
        }
        guard let body = Data(base64Encoded: try decode(Answer.self, data).body) else {
            throw .malformed
        }
        return body
    }

    public func activate(_ sub: RelaySubscription, device: RelayDevice) async throws(PushError) {
        _ = try await send(
            "POST", "subscriptions/\(try segment(sub.id))/activate", secret: device.secret, expect: [204])
    }

    public func unsubscribe(_ sub: RelaySubscription, device: RelayDevice) async throws(PushError) {
        _ = try await send("DELETE", "subscriptions/\(try segment(sub.id))", secret: device.secret, expect: [204])
    }

    /// A device-authenticated call to `path` (segments only, no query) under the base URL, for a
    /// push method's own routes: the status and body whatever the status. A path with anything
    /// but base64url segments is `.malformed`, and nothing is sent.
    public func deviceCall(
        _ method: String, _ path: String, body: Data?, device: RelayDevice
    ) async throws(PushError) -> (status: Int, body: Data) {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, segments.count <= 8, segments.allSatisfy({ !$0.isEmpty }) else {
            throw .malformed
        }
        for segment in segments {
            _ = try self.segment(String(segment))
        }
        return try await exchange(method, path, body: body, secret: device.secret)
    }

    // MARK: - Wire

    private func send(
        _ method: String, _ path: String, json: (any Encodable)? = nil, secret: String? = nil, expect: Set<Int>
    ) async throws(PushError) -> (Int, Data) {
        var body: Data?
        if let json {
            guard let encoded = try? JSONEncoder().encode(json) else {
                throw .malformed
            }
            body = encoded
        }
        let (status, data) = try await exchange(method, path, body: body, secret: secret)
        if expect.contains(status) {
            return (status, data)
        }
        switch status {
        case 409:
            throw .limit
        case 429:
            throw .rateLimited
        case 403:
            throw .attest
        default:
            throw .http(status)
        }
    }

    private func exchange(
        _ method: String, _ path: String, body: Data?, secret: String?
    ) async throws(PushError) -> (Int, Data) {
        guard base.scheme == "https" || Self.isLoopback(base) else {
            throw .transport
        }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await fetch(request)
    }

    private func fetch(_ request: URLRequest) async throws(PushError) -> (Int, Data) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PushError.malformed
            }
            if http.expectedContentLength > Int64(Self.maxResponse) {
                throw PushError.malformed
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxResponse {
                    throw PushError.malformed
                }
            }
            return (http.statusCode, data)
        } catch let error as PushError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch {
            throw .transport
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(PushError) -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw .malformed
        }
        return value
    }

    /// An id from the relay goes into a path as one segment only.
    private func segment(_ id: String) throws(PushError) -> String {
        guard !id.isEmpty, id.utf8.allSatisfy({ Self.safe.contains($0) }) else {
            throw .malformed
        }
        return id
    }

    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host else {
            return false
        }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}
