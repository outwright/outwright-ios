// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightNet

/// A JMAP client for push subscriptions (RFC 8620 section 7.2) of the type `EmailDelivery`
/// (RFC 8621). Answers are capped at 1 MiB; the password goes only into the Authorization header.
public actor JMAPClient {
    static let maxResponse = 1 << 20
    private let endpoint: JMAPEndpoint
    private let apiURL: URL
    private let authorization: String
    private let session: URLSession

    init(endpoint: JMAPEndpoint, apiURL: URL, authorization: String, session: URLSession) {
        self.endpoint = endpoint
        self.apiURL = apiURL
        self.authorization = authorization
        self.session = session
    }

    /// Reads the session object from `https://<host>/.well-known/jmap` (one same-host redirect).
    public static func discover(
        host: String, user: String, password: Secret, session: URLSession = .shared
    ) async throws(JMAPError) -> JMAPClient {
        struct Answer: Decodable {
            let apiUrl: String
            let username: String?
        }
        let endpoint = try JMAPEndpoint(host)
        guard let start = endpoint.wellKnown else {
            throw .malformed
        }
        let credentials = Data("\(user):\(password.reveal())".utf8).base64EncodedString()
        let authorization = "Basic \(credentials)"
        var request = URLRequest(url: start, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let redirects = SameHostRedirects(limit: 1, endpoint: endpoint, authorization: authorization)
        let data = try await fetch(request, session: session, delegate: redirects)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), let api = URL(string: answer.apiUrl),
            endpoint.owns(api)
        else {
            throw .malformed
        }
        // Stalwart answers a session it did not sign in with 200 and an empty username.
        guard answer.username?.isEmpty != true else {
            throw .auth
        }
        return JMAPClient(endpoint: endpoint, apiURL: api, authorization: authorization, session: session)
    }

    /// Creates an `EmailDelivery` push subscription; returns its JMAP id. The server then sends a
    /// `PushVerification` to `url`, which `verify` answers.
    public func createPushSubscription(
        deviceClientID: String, url: URL, keys: (p256dh: String, auth: String), expires: Date
    ) async throws(JMAPError) -> String {
        let create: [String: Any] = [
            "deviceClientId": deviceClientID, "url": url.absoluteString,
            "keys": ["p256dh": keys.p256dh, "auth": keys.auth],
            "expires": Self.utc(expires), "types": ["EmailDelivery"]
        ]
        let result = try await set(["create": ["c1": create]])
        guard let created = (result["created"] as? [String: Any])?["c1"] as? [String: Any],
            let id = created["id"] as? String, !id.isEmpty
        else {
            throw Self.refusal(result["notCreated"])
        }
        return id
    }

    /// Answers the `PushVerification` with its code (RFC 8620 section 7.2.2).
    public func verify(_ id: String, code: String) async throws(JMAPError) {
        try await update(id, ["verificationCode": code])
    }

    /// Moves the subscription's expiry.
    public func renew(_ id: String, expires: Date) async throws(JMAPError) {
        try await update(id, ["expires": Self.utc(expires)])
    }

    public func destroy(_ id: String) async throws(JMAPError) {
        let result = try await set(["destroy": [id]])
        guard let gone = result["destroyed"] as? [String], gone.contains(id) else {
            throw Self.refusal(result["notDestroyed"])
        }
    }

    // MARK: - Wire

    private func update(_ id: String, _ patch: [String: Any]) async throws(JMAPError) {
        let result = try await set(["update": [id: patch]])
        guard let updated = result["updated"] as? [String: Any], updated.keys.contains(id) else {
            let reason = ((result["notUpdated"] as? [String: Any])?[id] as? [String: Any])?["type"] as? String
            throw reason == "notFound" ? .notFound : Self.refusal(result["notUpdated"])
        }
    }

    private func set(_ arguments: [String: Any]) async throws(JMAPError) -> [String: Any] {
        let call: [Any] = ["PushSubscription/set", arguments, "0"]
        // `EmailDelivery` is a mail type (RFC 8621), so the call uses mail beside core.
        let using = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
        let envelope: [String: Any] = ["using": using, "methodCalls": [call]]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
            throw .malformed
        }
        var request = URLRequest(url: apiURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let redirects = SameHostRedirects(limit: 0, endpoint: endpoint, authorization: authorization)
        let data = try await Self.fetch(request, session: session, delegate: redirects)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let responses = root["methodResponses"] as? [[Any]], let first = responses.first, first.count >= 2,
            let name = first[0] as? String, let result = first[1] as? [String: Any]
        else {
            throw .malformed
        }
        guard name == "PushSubscription/set" else {
            throw .refused
        }
        return result
    }

    private static func refusal(_ rejected: Any?) -> JMAPError {
        rejected == nil ? .malformed : .refused
    }

    private static func utc(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func fetch(
        _ request: URLRequest, session: URLSession, delegate: SameHostRedirects
    ) async throws(JMAPError) -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw JMAPError.malformed
            }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw JMAPError.auth
            default: throw JMAPError.http(http.statusCode)
            }
            if http.expectedContentLength > Int64(maxResponse) {
                throw JMAPError.malformed
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxResponse {
                    throw JMAPError.malformed
                }
            }
            return data
        } catch let error as JMAPError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch {
            throw .transport
        }
    }
}

/// The verification code in a decrypted `PushVerification` (RFC 8620 section 7.2.2) for this
/// subscription, or nil when the body is anything else.
public func pushVerificationCode(from json: Data, subscriptionID: String) -> String? {
    struct Verification: Decodable {
        let type: String
        let pushSubscriptionId: String
        let verificationCode: String

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case pushSubscriptionId, verificationCode
        }
    }
    guard json.count <= 8 * 1024, let value = try? JSONDecoder().decode(Verification.self, from: json),
        value.type == "PushVerification", value.pushSubscriptionId == subscriptionID, !value.verificationCode.isEmpty
    else {
        return nil
    }
    return value.verificationCode
}
