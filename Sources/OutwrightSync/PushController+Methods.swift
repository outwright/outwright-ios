// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightPush

/// Which push method an account's push is made with.
extension PushController {
    /// The first method that offers push for the account; never an addressed one, which the
    /// owner chooses by asking for an address.
    func offering(_ account: Account) async -> (any PushMethod)? {
        for method in methods where !(method is any AddressedPushMethod) {
            guard await method.offers(account) else {
                continue
            }
            return method
        }
        return nil
    }

    func chosen(_ method: (any PushMethod)?, for account: Account) async -> (any PushMethod)? {
        if let method {
            return method
        }
        return await offering(account)
    }

    /// The method a registration was made with; nil when this build has no such method.
    func method(_ kind: PushMethodKind) -> (any PushMethod)? {
        methods.first { $0.kind == kind }
    }

    /// What a method needs to set up the server side of `sub`.
    func setup(
        _ account: Account, sub: RelaySubscription, device: RelayDevice, address: PushAddress? = nil
    ) -> PushSetup {
        PushSetup(
            account: account, subscription: sub, deviceClientID: device.deviceID,
            until: now().addingTimeInterval(Self.lifetime),
            awaitHeld: { [self] match async throws(PushError) -> String in
                try await held(sub, device: device, match: match)
            },
            keepSecret: { [registry] secret throws(PushError) in
                do {
                    try registry.setSecret(secret, subscriptionID: sub.id)
                } catch {
                    throw .storage
                }
            },
            relay: access(sub, device: device), address: address)
    }

    /// Runs a step that keeps something on the phone; its failure is `.storage`.
    func kept<T>(_ body: () throws(SyncError) -> T) throws(PushError) -> T {
        do {
            return try body()
        } catch {
            throw .storage
        }
    }

    /// The relay as `device`, for a push method's own routes of `sub`.
    func access(_ sub: RelaySubscription, device: RelayDevice) -> RelayAccess {
        let relay = relay
        return RelayAccess(subscription: sub) { method, path, body async throws(PushError) in
            try await relay.deviceCall(method, path, body: body, device: device)
        }
    }
}
