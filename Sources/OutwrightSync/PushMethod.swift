// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightPush

/// Which method a registration was made with; kept in the registry.
public struct PushMethodKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PushMethodKind {
    /// JMAP `PushSubscription` (RFC 8620 §7.2), Stalwart's push.
    public static let jmap = PushMethodKind(rawValue: "jmap")
}

/// Polls the relay's held body until `match` returns a value; `.timeout` at the deadline.
public typealias HeldBodyWait =
    @Sendable (_ match: @escaping @Sendable (Data) -> String?) async throws(PushError) -> String

/// A push method's way to the relay as the device its subscription is on: device-authenticated
/// calls to `path` (segments only, under the relay's base URL), for routes of the method's own.
public struct RelayAccess: Sendable {
    public typealias Call =
        @Sendable (_ method: String, _ path: String, _ body: Data?) async throws(PushError) -> (status: Int, body: Data)

    public let subscription: RelaySubscription
    public let call: Call

    public init(subscription: RelaySubscription, call: @escaping Call) {
        self.subscription = subscription
        self.call = call
    }
}

/// What a method needs to set up the server side of one relay subscription.
public struct PushSetup: Sendable {
    public let account: Account
    public let subscription: RelaySubscription
    public let deviceClientID: String
    /// When a server-side subscription that lapses should lapse (renewal moves it on).
    public let until: Date
    /// Polls the relay's held body until `match` returns a value, or throws `.timeout` at the
    /// deadline.
    public let awaitHeld: HeldBodyWait
    /// Keeps a secret in the vault under the subscription's keys entry, removed with the
    /// registration.
    public let keepSecret: @Sendable (Data) throws(PushError) -> Void
    /// The relay as this subscription's device.
    public let relay: RelayAccess
    /// For an addressed method: the address the owner's sender posts to, which `subscribe` checks.
    public let address: PushAddress?

    public init(
        account: Account, subscription: RelaySubscription, deviceClientID: String, until: Date,
        awaitHeld: @escaping HeldBodyWait,
        keepSecret: @escaping @Sendable (Data) throws(PushError) -> Void,
        relay: RelayAccess, address: PushAddress? = nil
    ) {
        self.relay = relay
        self.address = address
        self.account = account
        self.subscription = subscription
        self.deviceClientID = deviceClientID
        self.until = until
        self.awaitHeld = awaitHeld
        self.keepSecret = keepSecret
    }
}

/// What renewing a server-side subscription found.
public enum PushRenewal: Sendable, Equatable {
    /// Still there (moved on, or written again).
    case kept
    /// The mail server no longer has it: push is made again from scratch.
    case gone
    /// The mail server could not be asked; tried again on the next run.
    case unknown
}

/// One way of making a mail server push to the relay: the extension point push methods join.
/// The build's composition lists them; the first that offers push for an account is used.
public protocol PushMethod: Sendable {
    var kind: PushMethodKind { get }
    /// Where the account's server side is set up, once `subscribe` found it is not; nil when there
    /// is nothing to set up or no guide fits that server. Asks the mail server nothing.
    func setupGuide(for account: Account) async -> URL?
    /// Whether this account's server can push this way. Any failure is false.
    func offers(_ account: Account) async -> Bool
    /// Makes the server push to the subscription and proves it does; returns the server-side
    /// handle. Undoes whatever it made before throwing.
    func subscribe(_ setup: PushSetup) async throws(PushError) -> String
    /// Moves the server side on to `until`. `relay` is the relay as the registration's device; nil
    /// when the device is not registered there (renewal then works on the mail server alone).
    func renew(_ handle: String, account: Account, until: Date, relay: RelayAccess?) async -> PushRenewal
    /// Removes the server side; called while the relay subscription still exists.
    func remove(_ handle: String, account: Account, relay: RelayAccess?) async throws(PushError)
}

/// An address a sender of the owner's posts to, and the method's handle for it.
public struct PushAddress: Codable, Sendable, Equatable {
    public let handle: String
    public let url: URL

    public init(handle: String, url: URL) {
        self.handle = handle
        self.url = url
    }
}

/// A push method whose server side is a sender the owner sets up with an address the app shows.
/// Never chosen automatically: the owner asks for an address first, and `subscribe` (with
/// `PushSetup.address`) checks that the sender posts to it.
public protocol AddressedPushMethod: PushMethod {
    /// Whether `url` is an address this method hands out on the relay at `relayBase`; asked
    /// before anything is made at the relay, so text that is not one is refused at once.
    func recognizes(_ url: URL, relayBase: URL) -> Bool
    /// Makes a new address for the subscription.
    func issue(relay: RelayAccess) async throws(PushError) -> PushAddress
    /// Joins the subscription to an address a sender already posts to; nil when it is not one.
    func join(_ url: URL, relay: RelayAccess) async throws(PushError) -> PushAddress?
}
