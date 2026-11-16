// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightPush

/// Which push method an account's push is made with.
extension PushController {
    /// The first method that offers push for the account.
    func offering(_ account: Account) async -> (any PushMethod)? {
        for method in methods where await method.offers(account) {
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

    /// The relay as `device`, for a push method's own routes of `sub`.
    func access(_ sub: RelaySubscription, device: RelayDevice) -> RelayAccess {
        let relay = relay
        return RelayAccess(subscription: sub) { method, path, body async throws(PushError) in
            try await relay.deviceCall(method, path, body: body, device: device)
        }
    }
}
