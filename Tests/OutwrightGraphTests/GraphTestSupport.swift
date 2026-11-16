// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Synchronization

@testable import OutwrightGraph

/// Counts the renewals a client asked for.
final class Renewals: Sendable {
    let count = Mutex(0)
    let token = Mutex("token-1")
}

/// A fake Graph server and a client for it whose token is `renewals.token`.
func withGraph(_ body: (FakeGraphServer, GraphClient, Renewals) async throws -> Void) async throws {
    let server = FakeGraphServer()
    let base = try await server.start()
    let renewals = Renewals()
    let client = GraphClient(
        base: base, session: URLSession(configuration: .ephemeral),
        token: { renewals.token.withLock { $0 } },
        renew: { _ in
            renewals.count.withLock { $0 += 1 }
            renewals.token.withLock { $0 = "token-2" }
            return true
        })
    do {
        try await body(server, client, renewals)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

/// A Graph contact with every property the app maps, plus one it does not (`jobTitle`).
var fullContact: [String: Any] {
    [
    "givenName": "Maja", "surname": "Ek", "displayName": "Maja Ek", "companyName": "Ek AB",
    "personalNotes": "Met in Lund", "jobTitle": "Chief",
    "emailAddresses": [["name": "Maja", "address": "maja@example.org"], ["address": "ek@example.org"]],
    "mobilePhone": "+46 70 111", "businessPhones": ["+46 8 222"], "homePhones": ["+46 8 333", "+46 8 444"],
    "homeAddress": ["street": "Storgatan 1", "city": "Lund", "state": "", "postalCode": "222 22",
                    "countryOrRegion": "Sweden"],
        "businessAddress": [:] as [String: Any],
    ]
}
