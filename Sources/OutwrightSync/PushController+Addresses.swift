// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightPush

/// Push through an address the owner's own sender posts to: the address is issued (or joined)
/// first and kept, and switching push on checks it. It outlives a failed check and a relaunch,
/// so the owner sets the sender up once; once checked it takes over from any other method.
extension PushController {
    /// Whether an addressed method offers this account.
    public func addressOffered(_ account: Account) async -> Bool {
        await addressed(for: account) != nil
    }

    /// The account's address: the one issued and not yet checked, or the one push is on with.
    public func address(for account: AccountID) -> URL? {
        registry.issued(for: account)?.address.url ?? registry.registration(for: account)?.address
    }

    /// Whether push is on through the account's address (not through another method).
    public func isAddressActive(_ account: AccountID) -> Bool {
        registry.issued(for: account) == nil && registry.registration(for: account)?.address != nil
    }

    /// Whether the account's address was dropped since it was last handed out (its channel or
    /// relay subscription went away): the settings say so until a new one is issued or removed.
    public func addressDropped(_ account: AccountID) -> Bool {
        registry.isDropped(account)
    }

    /// Hands out the account's address: a new one, or with `joining` the one a sender already
    /// posts to. An address already issued or on is returned as it is, unless another is joined;
    /// text that is not one of the method's addresses is refused before the relay is asked.
    public func issueAddress(_ account: Account, joining: URL?) async throws(PushError) -> URL {
        await acquire()
        defer { release() }
        let current = address(for: account.id)
        if let current, joining == nil || joining == current {
            return current
        }
        guard let method = await addressed(for: account) else {
            throw .unsupported
        }
        if let joining, !method.recognizes(joining, relayBase: relay.baseURL) {
            throw .unknownAddress
        }
        guard let token else {
            throw .noDeviceToken
        }
        let (sub, device) = try await subscribed(token)
        let address: PushAddress
        do throws(PushError) {
            let relayAccess = access(sub, device: device)
            if let joining {
                guard let joined = try await method.join(joining, relay: relayAccess) else {
                    throw .unknownAddress
                }
                address = joined
            } else {
                address = try await method.issue(relay: relayAccess)
            }
        } catch {
            await unsubscribe(sub, device: device)
            throw error
        }
        // The new address is in place: the one it replaces goes.
        try? await removeAddressHeld(account.id)
        do throws(PushError) {
            try kept { () throws(SyncError) in
                try registry.saveIssued(PushIssued(account: account, relay: sub, method: method.kind, address: address))
            }
        } catch {
            await unsubscribe(sub, device: device)
            throw error
        }
        try? registry.setDropped(false, for: account.id)
        return address.url
    }

    /// Ends the account's address, whether push is on with it or it is only issued; push through
    /// another method stays.
    public func removeAddress(_ account: AccountID) async throws(PushError) {
        await acquire()
        defer { release() }
        try await removeAddressHeld(account)
        try? registry.setDropped(false, for: account)
    }

    func removeAddressHeld(_ account: AccountID) async throws(PushError) {
        if let registration = registry.registration(for: account), registration.address != nil {
            try await disableHeld(account)
        } else {
            await removeIssuedHeld(account)
        }
    }

    /// Removes the account's issued address: its channel membership, its pending subscription and
    /// the record. Best effort at the relay; the record goes whatever it answers.
    func removeIssuedHeld(_ account: AccountID) async {
        guard let issued = registry.issued(for: account) else {
            return
        }
        if let device = try? registry.device()?.device, let method = method(issued.method) {
            let relayAccess = access(issued.relay, device: device)
            try? await method.remove(issued.address.handle, account: issued.account, relay: relayAccess)
            await unsubscribe(issued.relay, device: device)
        }
        try? registry.removeIssued(for: account)
    }

    /// Switches push on with the issued address: the method checks it. A failed check keeps the
    /// address (and its pending subscription) for the next try, and any other method's push stays
    /// on; a passed one takes over from it. An issued subscription the relay no longer has drops
    /// the address.
    func enableIssued(_ account: Account, issued: PushIssued) async throws(PushError) {
        guard let method = method(issued.method) else {
            throw .unsupported
        }
        guard let device = try kept({ () throws(SyncError) in try registry.device() })?.device else {
            await dropIssued(account.id)
            throw .unknownAddress
        }
        let handle: String
        do {
            let made = setup(account, sub: issued.relay, device: device, address: issued.address)
            handle = try await method.subscribe(made)
        } catch .http(401), .http(404) {
            await dropIssued(account.id)
            throw .unknownAddress
        }
        let previous = registry.registrations().filter { $0.account.id == account.id }
        do {
            try startRenewals(subscriptionID: issued.relay.id)
            try kept { () throws(SyncError) in
                try registry.save(PushRegistration(
                    account: account, relay: issued.relay, method: method.kind, handle: handle,
                    address: issued.address.url))
            }
            try await retrying { () async throws(PushError) in
                try await self.relay.activate(issued.relay, device: device)
            }
        } catch {
            try? registry.remove(subscriptionID: issued.relay.id)
            try? marks.remove(issued.relay.id)
            throw error
        }
        try? registry.removeIssued(for: account.id)
        try? registry.setDropped(false, for: account.id)
        for old in previous {
            await retire(old, device: device)
        }
    }

    /// Ends a registration another has replaced: its server side, its relay subscription, and
    /// what is kept for it.
    private func retire(_ registration: PushRegistration, device: RelayDevice) async {
        if let method = method(registration.method) {
            let relayAccess = access(registration.relay, device: device)
            try? await method.remove(registration.handle, account: registration.account, relay: relayAccess)
        }
        await unsubscribe(registration.relay, device: device)
        try? registry.remove(subscriptionID: registration.relay.id)
        try? marks.remove(registration.relay.id)
    }

    private func dropIssued(_ account: AccountID) async {
        await removeIssuedHeld(account)
        try? registry.setDropped(true, for: account)
    }

    /// Switches off an addressed registration whose address is gone: nothing posts to a new one.
    /// The settings say it was dropped.
    func dropAddressed(_ registration: PushRegistration, device: RelayDevice?) async {
        if let device {
            await unsubscribe(registration.relay, device: device)
        }
        try? registry.remove(subscriptionID: registration.relay.id)
        try? marks.remove(registration.relay.id)
        try? registry.setDropped(true, for: registration.account.id)
    }

    /// The relay lost the subscription of an addressed registration: a new one joins the same
    /// address (which proved itself already) and is activated; an address that is gone too
    /// switches push off.
    func rejoin(_ registration: PushRegistration, method: any AddressedPushMethod, token: Data) async {
        let (sub, device): (RelaySubscription, RelayDevice)
        do {
            (sub, device) = try await subscribed(token)
        } catch {
            if !Task.isCancelled, Self.isRefusal(error) {
                await dropAddressed(registration, device: try? registry.device()?.device)
            }
            return
        }
        do throws(PushError) {
            guard let url = registration.address,
                let address = try await method.join(url, relay: access(sub, device: device))
            else {
                throw .unknownAddress
            }
            try startRenewals(subscriptionID: sub.id)
            try kept { () throws(SyncError) in
                try registry.save(PushRegistration(
                    account: registration.account, relay: sub, method: method.kind, handle: address.handle,
                    address: url))
            }
            try await retrying { () async throws(PushError) in try await self.relay.activate(sub, device: device) }
        } catch {
            await unsubscribe(sub, device: device)
            try? registry.remove(subscriptionID: sub.id)
            if !Task.isCancelled, Self.isRefusal(error) {
                await dropAddressed(registration, device: device)
            }
            return
        }
        await unsubscribe(registration.relay, device: device)
        try? registry.remove(subscriptionID: registration.relay.id)
        try? marks.remove(registration.relay.id)
    }

    /// Removes a relay subscription in a task of its own, so a cancelled caller still does.
    private func unsubscribe(_ sub: RelaySubscription, device: RelayDevice) async {
        let relay = relay
        await Task { try? await relay.unsubscribe(sub, device: device) }.value
    }

    /// The first addressed method that offers the account.
    private func addressed(for account: Account) async -> (any AddressedPushMethod)? {
        for case let method as any AddressedPushMethod in methods where await method.offers(account) {
            return method
        }
        return nil
    }
}
