// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation

/// A push subscription the fake JMAP server holds.
public struct FakeJMAPSubscription: Sendable {
    public var id: String
    public var deviceClientID: String
    public var url: String
    public var p256dh: String
    public var auth: String
    public var types: [String]
    public var expires: String
    public var verificationCode: String
    public var verified = false
}

/// A JMAP server on 127.0.0.1 for tests: Basic auth, the session object (behind a same-host
/// redirect, as Stalwart does) and `PushSubscription/set`. It encrypts its pushes per RFC 8291
/// (`aes128gcm`) and POSTs them to the subscription's url, like a mail server.
public actor FakeJMAPServer {
    public let user: String
    public let password: String
    private var server: FakeHTTPServer?
    private var port: UInt16 = 0
    private var counter = 0
    private var forcedSession: FakeHTTPResponse?
    private var apiAnswerDelay: Duration?
    /// The subscriptions by JMAP id.
    public private(set) var subscriptions: [String: FakeJMAPSubscription] = [:]
    /// The account id the state changes name.
    public let accountID = "a1"

    public init(user: String = "user@example.org", password: String = "correct horse") {
        self.user = user
        self.password = password
    }

    /// Starts serving; returns the host ("127.0.0.1:port") `JMAPClient.discover` takes.
    public func start() async throws -> String {
        let server = FakeHTTPServer { [weak self] request in
            guard let self else { return FakeHTTPResponse(status: 500) }
            let response = await self.handle(request)
            if request.method == "POST", let delay = await self.apiAnswerDelay {
                // The call has taken effect; only its answer is late, as on a slow network.
                try? await Task.sleep(for: delay)
            }
            return response
        }
        self.server = server
        port = try await server.start()
        return "127.0.0.1:\(port)"
    }

    public func stop() {
        server?.stop()
    }

    /// Forgets a subscription, as a server does when it lapses or after a restore.
    public func forget(_ jmapID: String) {
        subscriptions[jmapID] = nil
    }

    /// Holds every API answer back this long after the call has taken effect (nil: at once).
    public func delayAPIAnswers(_ delay: Duration?) {
        apiAnswerDelay = delay
    }

    /// Answers the session request with this response (nil: back to normal).
    public func forceSession(_ response: FakeHTTPResponse?) {
        forcedSession = response
    }

    // MARK: - Pushing

    /// Sends the `PushVerification` for a subscription to its url. Returns the HTTP status the url answered.
    @discardableResult
    public func sendVerification(_ jmapID: String, to relay: FakeRelay) async -> Int? {
        guard let sub = subscriptions[jmapID] else {
            return nil
        }
        let object: [String: Any] = [
            "@type": "PushVerification", "pushSubscriptionId": jmapID, "verificationCode": sub.verificationCode
        ]
        return await post(object, to: sub)
    }

    /// Sends a `StateChange` for new `EmailDelivery` state to a subscription's url.
    @discardableResult
    public func deliverEmail(_ jmapID: String, to relay: FakeRelay) async -> Int? {
        guard let sub = subscriptions[jmapID], sub.verified, sub.types.contains("EmailDelivery") else {
            return nil
        }
        counter += 1
        let object: [String: Any] = [
            "@type": "StateChange", "changed": [accountID: ["EmailDelivery": "state\(counter)"]]
        ]
        return await post(object, to: sub)
    }

    private func post(_ object: [String: Any], to sub: FakeJMAPSubscription) async -> Int? {
        guard let plain = try? JSONSerialization.data(withJSONObject: object), let url = URL(string: sub.url),
            let body = Self.encrypt(plain, p256dh: sub.p256dh, auth: sub.auth)
        else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("60", forHTTPHeaderField: "TTL")
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// RFC 8291 section 3 with a single RFC 8188 record, record size 4096.
    static func encrypt(_ plain: Data, p256dh: String, auth: String) -> Data? {
        guard let receiverBytes = unbase64url(p256dh), let authSecret = unbase64url(auth),
            let receiver = try? P256.KeyAgreement.PublicKey(x963Representation: receiverBytes)
        else {
            return nil
        }
        let sender = P256.KeyAgreement.PrivateKey()
        guard let secret = try? sender.sharedSecretFromKeyAgreement(with: receiver) else {
            return nil
        }
        let senderPublic = sender.publicKey.x963Representation
        let keyInfo = Data("WebPush: info".utf8) + [0] + receiverBytes + senderPublic
        let ikm = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32)
        var salt = Data()
        for _ in 0..<16 {
            salt.append(UInt8.random(in: 0...255))
        }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(
            pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm".utf8) + [0], outputByteCount: 16)
        let nonceBytes = HKDF<SHA256>.expand(
            pseudoRandomKey: prk, info: Data("Content-Encoding: nonce".utf8) + [0], outputByteCount: 12)
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes.withUnsafeBytes { Data($0) }),
            let box = try? AES.GCM.seal(plain + [2], using: cek, nonce: nonce)
        else {
            return nil
        }
        let recordSize: [UInt8] = [0, 0, 0x10, 0]
        return salt + recordSize + [UInt8(senderPublic.count)] + senderPublic + box.ciphertext + box.tag
    }

    static func unbase64url(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 {
            standard += "="
        }
        return Data(base64Encoded: standard)
    }

    // MARK: - Routes

    private func handle(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        let expected = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        guard request.headers["authorization"] == expected else {
            return FakeHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"jmap\""])
        }
        switch (request.method, request.path) {
        case ("GET", "/.well-known/jmap"):
            return forcedSession ?? FakeHTTPResponse(status: 302, headers: ["Location": "/jmap/session"])
        case ("GET", "/jmap/session"):
            return forcedSession ?? .json(
                200,
                """
                {"capabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{}},\
                "accounts":{"\(accountID)":{"name":"\(user)"}},\
                "primaryAccounts":{"urn:ietf:params:jmap:mail":"\(accountID)"},"username":"\(user)",\
                "apiUrl":"http://127.0.0.1:\(port)/jmap/","state":"s"}
                """)
        case ("POST", "/jmap/"):
            return api(request.body)
        default:
            return FakeHTTPResponse(status: 404)
        }
    }

    private func api(_ body: Data) -> FakeHTTPResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let calls = root["methodCalls"] as? [[Any]], let call = calls.first, call.count == 3,
            call[0] as? String == "PushSubscription/set", let args = call[1] as? [String: Any]
        else {
            return FakeHTTPResponse(status: 400)
        }
        // `EmailDelivery` is a mail type: a call that does not use mail does not know it.
        let using = root["using"] as? [String] ?? []
        guard using.contains("urn:ietf:params:jmap:core"), using.contains("urn:ietf:params:jmap:mail") else {
            return Self.respond([["error", ["type": "unknownMethod"], "0"]])
        }
        var result: [String: Any] = [:]
        if let create = args["create"] as? [String: [String: Any]] {
            var created: [String: Any] = [:], rejected: [String: Any] = [:]
            for (key, value) in create {
                if let id = add(value) {
                    created[key] = ["id": id]
                } else {
                    rejected[key] = ["type": "invalidProperties"]
                }
            }
            result["created"] = created
            result["notCreated"] = rejected
        }
        if let update = args["update"] as? [String: [String: Any]] {
            var updated: [String: Any] = [:], rejected: [String: Any] = [:]
            for (id, patch) in update {
                if subscriptions[id] == nil {
                    rejected[id] = ["type": "notFound"]
                } else if change(id, patch) {
                    updated[id] = NSNull()
                } else {
                    rejected[id] = ["type": "invalidProperties"]
                }
            }
            result["updated"] = updated
            result["notUpdated"] = rejected
        }
        if let destroy = args["destroy"] as? [String] {
            let gone = destroy.filter { subscriptions.removeValue(forKey: $0) != nil }
            result["destroyed"] = gone
            result["notDestroyed"] = destroy.filter { !gone.contains($0) }.reduce(into: [String: Any]()) {
                $0[$1] = ["type": "notFound"]
            }
        }
        return Self.respond([["PushSubscription/set", result, "0"]])
    }

    private static func respond(_ responses: [[Any]]) -> FakeHTTPResponse {
        let envelope: [String: Any] = ["methodResponses": responses, "sessionState": "s"]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return FakeHTTPResponse(status: 500)
        }
        return FakeHTTPResponse(status: 200, body: data, headers: ["Content-Type": "application/json"])
    }

    private func add(_ value: [String: Any]) -> String? {
        guard let device = value["deviceClientId"] as? String, let url = value["url"] as? String,
            let keys = value["keys"] as? [String: String], let p256dh = keys["p256dh"], let auth = keys["auth"],
            let expires = value["expires"] as? String
        else {
            return nil
        }
        counter += 1
        let id = "ps\(counter)"
        subscriptions[id] = FakeJMAPSubscription(
            id: id, deviceClientID: device, url: url, p256dh: p256dh, auth: auth,
            types: value["types"] as? [String] ?? [], expires: expires, verificationCode: "code-\(counter)")
        return id
    }

    private func change(_ id: String, _ patch: [String: Any]) -> Bool {
        guard var sub = subscriptions[id] else {
            return false
        }
        if let code = patch["verificationCode"] as? String {
            guard code == sub.verificationCode else {
                return false
            }
            sub.verified = true
        }
        if let expires = patch["expires"] as? String {
            sub.expires = expires
        }
        subscriptions[id] = sub
        return true
    }
}
