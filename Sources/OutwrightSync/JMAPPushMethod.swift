// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import OutwrightJMAP
import OutwrightNet
public import OutwrightPush

/// Push through a JMAP `EmailDelivery` subscription (RFC 8620 §7.2, RFC 8621) on the account's
/// JMAP host, verified through the relay with Web Push keys (RFC 8291) made on the phone.
public struct JMAPPushMethod: PushMethod {
    private let secrets: any SecretStore
    private let jmapHost: @Sendable (Account) -> String

    /// `jmapHost` is where the account's JMAP server is: its IMAP host unless a test says otherwise.
    public init(secrets: any SecretStore, jmapHost: @escaping @Sendable (Account) -> String = { $0.imap.host }) {
        self.secrets = secrets
        self.jmapHost = jmapHost
    }

    public var kind: PushMethodKind { .jmap }
    public func setupGuide(for account: Account) async -> URL? { nil }

    public func offers(_ account: Account) async -> Bool {
        (try? await client(account)) != nil
    }

    public func subscribe(_ setup: PushSetup) async throws(PushError) -> String {
        let keys = WebPushKeys.generate()
        try setup.keepSecret(keys.rawRepresentation)
        let client = try await client(setup.account)
        let expires = setup.until
        // In a task of its own, so a cancel cannot drop the answer: a subscription the mail server
        // made must be known here to be removed again.
        let deviceID = setup.deviceClientID, url = setup.subscription.pushURL, keyPair = (keys.p256dh, keys.authString)
        let answer = await Task { () async -> Result<String, JMAPError> in
            do throws(JMAPError) {
                return .success(try await client.createPushSubscription(
                    deviceClientID: deviceID, url: url, keys: keyPair, expires: expires))
            } catch {
                return .failure(error)
            }
        }.value
        let id = try await Self.viaJMAP { () throws(JMAPError) -> String in try answer.get() }
        do {
            let code = try await setup.awaitHeld { body in
                guard let plain = try? decryptWebPush(body, keys: keys) else {
                    return nil
                }
                return pushVerificationCode(from: plain, subscriptionID: id)
            }
            try await Self.viaJMAP { () async throws(JMAPError) in try await client.verify(id, code: code) }
            return id
        } catch {
            // In a task of its own: a cancelled setup still removes what it made on the server.
            await Task { try? await client.destroy(id) }.value
            throw error
        }
    }

    public func renew(_ handle: String, account: Account, until: Date, relay: RelayAccess?) async -> PushRenewal {
        guard let client = try? await client(account) else {
            return .unknown
        }
        do {
            try await client.renew(handle, expires: until)
            return .kept
        } catch {
            return error == .notFound ? .gone : .unknown
        }
    }

    public func remove(_ handle: String, account: Account, relay: RelayAccess?) async throws(PushError) {
        let client = try await client(account)
        try await Self.viaJMAP { () async throws(JMAPError) in try await client.destroy(handle) }
    }

    private func client(_ account: Account) async throws(PushError) -> JMAPClient {
        let stored: Secret?
        do {
            stored = try secrets.password(for: account.id)
        } catch {
            throw .storage
        }
        guard let password = stored else {
            throw .jmap
        }
        let host = jmapHost(account)
        return try await Self.viaJMAP { () async throws(JMAPError) -> JMAPClient in
            try await JMAPClient.discover(host: host, user: account.user, password: password)
        }
    }

    /// A JMAP call; the mail server not answering (unreachable, timed out, busy, a server error)
    /// stays apart from it refusing (`.jmap`).
    static func viaJMAP<T: Sendable>(_ body: () async throws(JMAPError) -> T) async throws(PushError) -> T {
        do {
            return try await body()
        } catch .timeout {
            throw .timeout
        } catch .transport {
            throw .transport
        } catch .http(let status) where status >= 500 || status == 429 || status == 408 {
            throw .transport
        } catch {
            throw .jmap
        }
    }
}
