// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightPush

// MARK: - Recovery

/// What `renewAll` does when the relay has lost the device or a subscription.
extension PushController {

    /// The stored device after telling the relay its current token (which also proves the relay
    /// still knows it), or nil when there is none or the relay no longer knows it. `token` is
    /// what a registration made now would use: this launch's, nil before APNs has given one
    /// (the stored one may be what APNs just refused) or when the relay could not be asked,
    /// and then nothing is made again.
    func checkedDevice() async -> (device: RelayDevice?, token: Data?) {
        guard let record = try? registry.device() else {
            return (nil, token)
        }
        let current = token ?? record.token
        do {
            try await retrying { () async throws(PushError) in
                try await self.relay.updateToken(current, device: record.device)
            }
        } catch .http(401), .http(404) {
            try? await forgetDevice()
            return (nil, token)
        } catch {
            return (record.device, nil)
        }
        if current != record.token {
            try? registry.setDevice(PushDeviceRecord(device: record.device, token: current))
        }
        return (record.device, token)
    }

    /// Whether the relay no longer has the subscription: no device, or a 404 for it on this one.
    func isLost(_ registration: PushRegistration, device: RelayDevice?) async -> Bool {
        guard let device else {
            return true
        }
        do {
            _ = try await retrying { () async throws(PushError) -> Data? in
                try await self.relay.pendingBody(registration.relay, device: device)
            }
            return false
        } catch {
            return error == .http(404) || error == .http(401)
        }
    }

    /// Moves the server side's expiry on; true when the mail server no longer has it. Other
    /// failures, and a method this build lacks, wait for the next run.
    func renewedIsGone(_ registration: PushRegistration, device: RelayDevice?) async -> Bool {
        guard let method = method(registration.method) else {
            return false
        }
        let until = now().addingTimeInterval(Self.lifetime)
        let relay = device.map { access(registration.relay, device: $0) }
        return await method.renew(registration.handle, account: registration.account, until: until, relay: relay)
            == .gone
    }

    /// Replaces a subscription the relay or the mail server lost. What is left of it on either
    /// goes first (it pushes nowhere), then push is switched on again. The old registration is
    /// dropped once that worked or was refused for good; after a passing failure (or a cancel)
    /// it stays, so the account shows on and the next run tries again.
    func reestablish(_ registration: PushRegistration, token: Data) async {
        if let addressed = method(registration.method) as? any AddressedPushMethod {
            await rejoin(registration, method: addressed, token: token)
            return
        }
        let method = method(registration.method)
        let device = try? registry.device()?.device
        if let method {
            try? await method.remove(
                registration.handle, account: registration.account,
                relay: device.map { access(registration.relay, device: $0) })
        }
        if let device {
            try? await relay.unsubscribe(registration.relay, device: device)
        }
        do {
            try await enableHeld(registration.account, token: token, using: method)
        } catch {
            guard !Task.isCancelled, Self.isRefusal(error) else {
                return
            }
        }
        try? registry.remove(subscriptionID: registration.relay.id)
        try? marks.remove(registration.relay.id)
    }

    /// A failure that trying again will not mend: the relay or the mail server said no.
    static func isRefusal(_ error: PushError) -> Bool {
        switch error {
        case .limit, .attest, .jmap, .noDeviceToken, .unsupported, .serverRefused, .notSetUp, .unknownAddress:
            true
        case .http(let status):
            (400..<500).contains(status) && status != 408
        default:
            false
        }
    }

    /// Forgets the relay device and its App Attest key: the next registration attests a new key.
    func forgetDevice() async throws(PushError) {
        try kept { () throws(SyncError) in try registry.forgetDevice() }
        await attester.forgetKey()
    }
}
