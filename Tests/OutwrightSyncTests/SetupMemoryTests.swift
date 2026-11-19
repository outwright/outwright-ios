// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightNet
import Testing

@testable import OutwrightSync

/// What a setup remembers between runs: kept answers and accounts left off, in the keychain.
@Suite struct SetupMemoryTests {
    @Test func roundTripsThroughTheSecretStore() throws {
        let secrets = InMemorySecretStore()
        let memory = SetupMemory(kept: ["accounts/password:pat@example.org": "abc"], leftOff: ["work@example.org"])

        try memory.save(to: secrets)

        #expect(SetupMemory.load(from: secrets) == memory)
    }

    @Test func missingMemoryIsEmpty() {
        #expect(SetupMemory.load(from: InMemorySecretStore()) == SetupMemory())
    }

    @Test func unreadableMemoryIsEmpty() throws {
        let secrets = InMemorySecretStore()
        try secrets.setSetupMemory(Secret("not json"))

        #expect(SetupMemory.load(from: secrets) == SetupMemory())
    }
}
