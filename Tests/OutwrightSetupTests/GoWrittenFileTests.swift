// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightSetup

/// A setup file the Go engine wrote (engine/adapters/setup, `TestGoWrittenFile`) opens on the phone, with every part
/// as the engine wrote it.
@Suite struct GoWrittenFileTests {
    /// The fixture's synthetic passphrase, the same as the Go test's.
    static let passphrase = "cobalt-dwelling-unwound-pebble-sincere-tadpole"

    static func file() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "go-written", withExtension: "outwright-setup", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func opensWithItsParts() throws {
        let bundle = try SetupBundle.opened(Self.file(), passphrase: Passphrase(typed: Self.passphrase))
        #expect(bundle.version == 1)
        #expect(bundle.device == "Outwright on a Mac")
        #expect(bundle.created == Date(timeIntervalSince1970: 1_795_075_200))
        #expect(bundle.parts.count == 3)
        #expect(
            bundle.parts["accounts"] == .init(version: 1, title: "Accounts", content: Data(#"{"accounts":[]}"#.utf8)))
        #expect(
            bundle.parts["subscriptions"]
                == .init(version: 1, title: "Subscriptions", content: Data(#"{"calendars":[]}"#.utf8)))
        #expect(bundle.parts["future"] == .init(version: 7, content: Data(#"{"x":true}"#.utf8)))
        #expect(bundle.label(of: "future") == "future")
    }

    @Test func refusesAnotherPassphrase() throws {
        let other = try Passphrase(typed: "abacus abdomen abdominal abide abiding ability")
        #expect(throws: SetupError.wrongPassphrase) { try SetupBundle.opened(Self.file(), passphrase: other) }
    }
}
