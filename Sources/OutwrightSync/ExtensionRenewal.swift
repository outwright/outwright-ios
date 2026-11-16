// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightPush

/// The notification extension's share of keeping push alive: when a push arrives, the server
/// side of its subscription is moved on, at most every 12 hours, through the registration's
/// method. What renewal finds is left to the app's `renewAll` (which makes push again when it is
/// gone); the extension only moves the expiry on, so an account whose mail comes but whose app is
/// never opened keeps its push.
public struct ExtensionRenewal: Sendable {
    public static let every: TimeInterval = 12 * 3_600

    private let registry: PushRegistry
    private let relay: RelayClient?
    private let methods: [any PushMethod]
    private let marks: PushWatermarks
    private let now: @Sendable () -> Date

    /// `relay` nil: the build has no relay, and methods renew on the mail server alone.
    public init(
        registry: PushRegistry, relay: RelayClient?, methods: [any PushMethod], marks: PushWatermarks,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.relay = relay
        self.methods = methods
        self.marks = marks
        self.now = now
    }

    /// Renews the subscription's server side when its last renewal is 12 hours old or more.
    public func renewIfDue(subscriptionID: String) async {
        let now = now()
        guard let registration = registry.registration(subscriptionID: subscriptionID),
            let method = methods.first(where: { $0.kind == registration.method }),
            (try? marks.claimRenewal(subscriptionID, now: now, every: Self.every)) == true
        else { return }
        var access: RelayAccess?
        if let relay, let device = try? registry.device()?.device {
            access = RelayAccess(subscription: registration.relay) { method, path, body async throws(PushError) in
                try await relay.deviceCall(method, path, body: body, device: device)
            }
        }
        _ = await method.renew(
            registration.handle, account: registration.account, until: now.addingTimeInterval(PushController.lifetime),
            relay: access)
    }
}
