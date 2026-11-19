// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightNet
import OutwrightSetup
import OutwrightStore
import Testing

@testable import OutwrightSync

/// A setup is brought more than once: an answer kept is not asked again until either side changes,
/// and an account left off stays off.
extension SetupExchangeTests {
    @Test func secondRunAsksNothing() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)

        let first = await device.exchange().preview(bundle)
        #expect(first.differences.count == 2)
        _ = await device.exchange().restore(first, replacing: [], leavingOff: [])

        let again = await device.exchange().preview(bundle)
        #expect(again.differences.isEmpty)
        let report = await device.exchange().restore(again, replacing: [], leavingOff: [])
        #expect(report.replaced.isEmpty)
        #expect(!report.changedAnything)
    }

    @Test func changedOtherSideAsksAgain() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)
        _ = await device.exchange().restore(await device.exchange().preview(bundle), replacing: [], leavingOff: [])

        let account = try #require(try original.store.accounts().first)
        try original.secrets.setPassword(Secret("changed there"), for: account.id)
        let (changed, _) = try await original.exchange().exportBundle()

        #expect(await device.exchange().preview(changed).differences.map(\.id) == ["password:pat@example.org"])
    }

    @Test func replacedIsNotRemembered() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)
        let first = await device.exchange().preview(bundle)
        let password = try #require(first.differences.first { $0.kind == .accountSecret })
        _ = await device.exchange().restore(first, replacing: [password], leavingOff: [])

        let account = try #require(try device.store.accounts().first)
        try device.secrets.setPassword(Secret("changed here"), for: account.id)

        #expect(await device.exchange().preview(bundle).differences.map(\.id) == ["password:pat@example.org"])
    }

    @Test func leftOffAccountIsNotAddedAndRemembered() async throws {
        let original = try sender()
        let work = setupAccount("work@example.org")
        try original.store.save(work)
        try original.secrets.setPassword(Secret("work"), for: work.id)
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try Device()

        let first = await device.exchange().preview(bundle)
        #expect(first.leftOff.isEmpty)
        let report = await device.exchange().restore(first, replacing: [], leavingOff: ["work@example.org"])
        #expect(try device.store.accounts().map(\.email) == ["pat@example.org"])
        #expect(report.skipped.contains(SetupSkip(item: accountItem("work@example.org"), reason: .leftOff)))

        let again = await device.exchange().preview(bundle)
        #expect(again.leftOff == ["work@example.org"])
        _ = await device.exchange().restore(again, replacing: [], leavingOff: [])
        #expect(try device.store.accounts().map(\.email).sorted() == ["pat@example.org", "work@example.org"])
        #expect(await device.exchange().preview(bundle).leftOff.isEmpty)
    }

    /// An account already here that the owner switches off is left as it is, whatever was chosen.
    @Test func leftOffAccountHereIsLeftAlone() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)
        let preview = await device.exchange().preview(bundle)

        let report = await device.exchange().restore(
            preview, replacing: Set(preview.differences), leavingOff: ["pat@example.org"])

        let account = try #require(try device.store.accounts().first)
        #expect(try device.secrets.password(for: account.id)?.reveal() == "chosen here")
        #expect(account.signature == "Signed here")
        #expect(report.replaced.isEmpty)
    }

    /// A difference of an account left off was never asked: switched on again, it is asked.
    @Test func anUnaskedDifferenceIsNotRemembered() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)
        _ = await device.exchange().restore(
            await device.exchange().preview(bundle), replacing: [], leavingOff: ["pat@example.org"])

        let again = await device.exchange().preview(bundle)
        #expect(again.differences.map(\.id) == ["password:pat@example.org", "signature:pat@example.org"])
    }

    /// Memory that cannot be read is left as it is, never written over with nothing.
    @Test func unreadableMemoryIsLeftAlone() async throws {
        let original = try sender()
        let (bundle, _) = try await original.exchange().exportBundle()
        let device = try deviceWithAnotherPassword(than: original)
        try device.secrets.setSetupMemory(Secret("not json"))

        _ = await device.exchange().restore(await device.exchange().preview(bundle), replacing: [], leavingOff: [])

        #expect(try device.secrets.setupMemory()?.reveal() == "not json")
    }
}
