// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightPush

/// How long push setup waits and how it backs off.
public struct PushTiming: Sendable {
    /// Between asks for the verification body.
    public var poll: Duration
    /// How long the mail server has to send its verification.
    public var verifyWithin: Duration
    /// The waits before each new try of a relay call the relay answered 429 (it sends no
    /// Retry-After); one more try than there are waits.
    public var backoffs: [Duration]

    public init(poll: Duration, verifyWithin: Duration, backoffs: [Duration]) {
        self.poll = poll
        self.verifyWithin = verifyWithin
        self.backoffs = backoffs
    }

    /// Polls every 2 s for 30 s; backs off 2, 4, 8, 16 and 30 s (a minute in all), which outlasts
    /// the relay's one-minute window.
    public static let standard = PushTiming(
        poll: .seconds(2), verifyWithin: .seconds(30),
        backoffs: [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
}

/// Switches push on and off per account: registers the device with the relay once, then per
/// account a relay subscription and the server side of the first push method that offers push
/// for it, which proves itself through the relay. Whatever a failed `enable` created is undone.
/// One operation runs at a time.
public actor PushController {
    /// A server-side subscription's life where it lapses; `renewAll` moves it on.
    static let lifetime: TimeInterval = 7 * 86_400
    static let maxPolls = 1_000

    let relay: RelayClient
    let attester: any DeviceAttester
    let registry: PushRegistry
    private let credentials: CredentialProvider
    let marks: PushWatermarks
    private let environment: APNsEnvironment
    let methods: [any PushMethod]
    /// The method the last `enable` of each account tried, for its setup guide.
    private var tried: [AccountID: PushMethodKind] = [:]
    private let timing: PushTiming
    let now: @Sendable () -> Date
    private(set) var token: Data?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `methods` in the order they are tried: the first that offers push for an account is used.
    public init(
        relay: RelayClient, attester: any DeviceAttester, registry: PushRegistry, credentials: CredentialProvider,
        marks: PushWatermarks, environment: APNsEnvironment, methods: [any PushMethod],
        timing: PushTiming = .standard, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.relay = relay
        self.attester = attester
        self.registry = registry
        self.credentials = credentials
        self.marks = marks
        self.environment = environment
        self.methods = methods
        self.timing = timing
        self.now = now
    }

    public func isEnabled(_ account: AccountID) -> Bool {
        registry.registration(for: account) != nil
    }

    /// Whether a method offers push for the account, or an address was issued for it: push can
    /// be switched on only then.
    public func offersPush(_ account: Account) async -> Bool {
        if registry.issued(for: account.id) != nil {
            return true
        }
        return await offering(account) != nil
    }

    /// Where the account's server side is set up, from the method the last `enable` for it tried;
    /// nothing is asked of the servers again.
    public func setupGuide(for account: Account) async -> URL? {
        guard let kind = tried[account.id], let method = method(kind) else {
            return nil
        }
        return await method.setupGuide(for: account)
    }

    /// The APNs token, from every launch. A registered device whose token changed tells the
    /// relay; a failure there is tried again on the next call. A device the relay no longer
    /// knows is forgotten, and the next `enable` registers it again.
    public func setDeviceToken(_ token: Data) async {
        await acquire()
        defer { release() }
        self.token = token
        guard var record = try? registry.device(), record.token != token else {
            return
        }
        let device = record.device
        do {
            try await retrying { () async throws(PushError) in try await self.relay.updateToken(token, device: device) }
            record.token = token
            try? registry.setDevice(record)
        } catch .http(401), .http(404) {
            try? await forgetDevice()
        } catch {
            return
        }
    }

    /// Switches push on: with the account's issued address when there is one (taking over from
    /// any other method once its check passes), else with the first method that offers push.
    public func enable(_ account: Account) async throws(PushError) {
        await acquire()
        defer { release() }
        if let issued = registry.issued(for: account.id) {
            try await enableIssued(account, issued: issued)
            return
        }
        guard registry.registration(for: account.id) == nil else {
            return
        }
        guard let token else {
            throw .noDeviceToken
        }
        try await enableHeld(account, token: token)
    }

    /// `enable` with the operation already held, through `using` or else the first method that
    /// offers push for the account. Making push again (`reestablish`) names the registration's own
    /// method: a mail server that is down then is a passing failure, not a refusal.
    func enableHeld(_ account: Account, token: Data, using: (any PushMethod)? = nil) async throws(PushError) {
        guard let method = await chosen(using, for: account) else {
            throw .unsupported
        }
        tried[account.id] = method.kind
        let (sub, device) = try await subscribed(token)
        var handle: String?
        do {
            let made = try await method.subscribe(setup(account, sub: sub, device: device))
            handle = made
            try startRenewals(subscriptionID: sub.id)
            try kept { () throws(SyncError) in
                try registry.save(PushRegistration(account: account, relay: sub, method: method.kind, handle: made))
            }
            try await retrying { () async throws(PushError) in try await self.relay.activate(sub, device: device) }
        } catch {
            // In a task of its own: a cancelled enable still undoes what it made on the servers.
            let made = handle, relay = relay, registry = registry, marks = marks
            let access = access(sub, device: device)
            await Task {
                if let made {
                    try? await method.remove(made, account: account, relay: access)
                }
                try? await relay.unsubscribe(sub, device: device)
                try? registry.remove(subscriptionID: sub.id)
                try? marks.remove(sub.id)
            }.value
            throw error
        }
    }

    /// Removes both subscriptions and everything kept for them. Local state goes whatever the
    /// servers answer; the first server failure is thrown afterwards.
    public func disable(_ account: AccountID) async throws(PushError) {
        await acquire()
        defer { release() }
        try await disableHeld(account)
    }

    /// `disable` with the operation already held. An address issued and not yet checked goes too.
    func disableHeld(_ account: AccountID) async throws(PushError) {
        await removeIssuedHeld(account)
        guard let registration = registry.registration(for: account) else {
            return
        }
        var failure: PushError?
        let device: RelayDevice?
        do {
            device = try kept { () throws(SyncError) in try registry.device() }?.device
        } catch {
            device = nil
            failure = error
        }
        // The method first, while the relay subscription is still there for it.
        do throws(PushError) {
            guard let method = method(registration.method) else {
                throw .unsupported
            }
            try await method.remove(
                registration.handle, account: registration.account,
                relay: device.map { access(registration.relay, device: $0) })
        } catch {
            failure = failure ?? error
        }
        do {
            if let device {
                try await retrying { () async throws(PushError) in
                    try await self.relay.unsubscribe(registration.relay, device: device)
                }
            }
        } catch .http(404) {
            // Already gone at the relay.
        } catch {
            failure = failure ?? error
        }
        do {
            try kept { () throws(SyncError) in try registry.remove(subscriptionID: registration.relay.id) }
        } catch {
            failure = failure ?? error
        }
        do {
            try kept { () throws(SyncError) in try marks.remove(registration.relay.id) }
        } catch {
            failure = failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    /// The account was changed in the app (its name, its mail server): the registration the
    /// notification extension reads takes the account as it is now. Nothing for one without push.
    public func accountChanged(_ account: Account) async {
        await acquire()
        defer { release() }
        try? registry.update(account)
    }

    /// Checks that the relay still knows the device and each subscription, then moves every JMAP
    /// subscription's expiry to a week from now. The relay drops a device (and its
    /// subscriptions) when APNs refuses its token, a restored relay can lack either, and the mail
    /// server can lose a subscription: one either no longer has is made again from scratch,
    /// with this launch's token only. An account where that is refused is switched off, so its
    /// switch shows the truth; one that fails for a passing reason stays on and is tried again
    /// on the next run.
    public func renewAll() async {
        await acquire()
        defer { release() }
        let registrations = registry.registrations()
        guard !registrations.isEmpty else {
            return
        }
        syncLog.info("push: renewing \(registrations.count, privacy: .public) registrations")
        let checked = await checkedDevice()
        for registration in registrations {
            guard !Task.isCancelled else {
                return
            }
            var lost = false
            if checked.token != nil {
                lost = await isLost(registration, device: checked.device)
            }
            if !lost, await renewedIsGone(registration, device: checked.device) {
                if method(registration.method) is any AddressedPushMethod {
                    // The owner's sender posts to that address: a new one would reach nobody.
                    await dropAddressed(registration, device: checked.device)
                    continue
                }
                lost = true
            }
            if lost, let token = checked.token {
                await reestablish(registration, token: token)
            }
        }
    }

}

// MARK: - Steps

extension PushController {

    /// A new relay subscription and the device it is on. A stored device the relay refuses
    /// (deleted after a bad APNs token, or an App Attest key it does not know) is registered
    /// again, once.
    func subscribed(_ token: Data) async throws(PushError) -> (RelaySubscription, RelayDevice) {
        let (device, fresh) = try await registeredDevice(token)
        do {
            return (try await subscribe(device), device)
        } catch {
            guard !fresh, [.attest, .http(401), .http(404)].contains(error) else {
                throw error
            }
            try await forgetDevice()
            let (again, _) = try await registeredDevice(token)
            return (try await subscribe(again), again)
        }
    }

    private func subscribe(_ device: RelayDevice) async throws(PushError) -> RelaySubscription {
        let keyID = try await attester.keyID()
        return try await retrying { () async throws(PushError) -> RelaySubscription in
            let challenge = try await self.relay.challenge()
            let assertion = try await self.attester.assert(keyID: keyID, challenge: challenge)
            return try await self.relay.subscribe(challenge: challenge, assertion: assertion, device: device)
        }
    }

    /// The relay device, registered (with an attestation) the first time; `fresh` when it was
    /// registered just now.
    private func registeredDevice(_ token: Data) async throws(PushError) -> (device: RelayDevice, fresh: Bool) {
        if let record = try kept({ () throws(SyncError) in try registry.device() }) {
            return (record.device, false)
        }
        let keyID = try await attester.keyID()
        let environment = environment
        let device = try await retrying { () async throws(PushError) -> RelayDevice in
            let challenge = try await self.relay.challenge()
            let attestation = try await self.attester.attest(keyID: keyID, challenge: challenge)
            return try await self.relay.registerDevice(
                keyID: keyID, attestation: attestation, challenge: challenge, token: token, environment: environment)
        }
        do {
            try kept { () throws(SyncError) in try registry.setDevice(PushDeviceRecord(device: device, token: token)) }
        } catch {
            try? await relay.removeDevice(device)
            throw error
        }
        return (device, true)
    }

    /// Asks the relay for the pending body until `match` takes it. A 429 skips that poll;
    /// polling goes on to the deadline.
    func held(
        _ sub: RelaySubscription, device: RelayDevice, match: @Sendable (Data) -> String?
    ) async throws(PushError) -> String {
        let deadline = ContinuousClock.now + timing.verifyWithin
        for _ in 0..<Self.maxPolls {
            let body: Data?
            do {
                body = try await relay.pendingBody(sub, device: device)
            } catch .rateLimited {
                body = nil
            }
            if let body, let found = match(body) {
                return found
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                break
            }
            try? await Task.sleep(for: timing.poll)
        }
        throw .timeout
    }

    /// The subscription's renewals from the notification extension start. Where its mail starts
    /// is the store's business, on the first push: the mailbox is not asked.
    func startRenewals(subscriptionID: String) throws(PushError) {
        do {
            try marks.start(subscriptionID)
        } catch {
            throw .storage
        }
    }

    // MARK: - Support

    /// Runs a relay call, waiting and trying again (a bounded number of times) when rate limited.
    func retrying<T: Sendable>(
        _ body: () async throws(PushError) -> T
    ) async throws(PushError) -> T {
        var waits = timing.backoffs[...]
        while true {
            do {
                return try await body()
            } catch {
                guard error == .rateLimited, let wait = waits.popFirst() else {
                    throw error
                }
                try? await Task.sleep(for: wait)
            }
        }
    }

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
