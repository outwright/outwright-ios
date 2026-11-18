// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightSync
import Testing

@Suite final class PushNoticeLogTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-notices-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func log() -> PushNoticeLog {
        PushNoticeLog(fileURL: folder.appendingPathComponent("push-notices.json"))
    }

    @Test func aDamagedFileReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json at all {{{".utf8).write(to: folder.appendingPathComponent("push-notices.json"))
        #expect(log().entries().isEmpty)
    }

    @Test func notesWithTheirDetailsRead() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"[{"date":1800000000,"why":"found","subscription":"0a80627d","count":2,"shown":"details"}]"#.utf8)
            .write(to: folder.appendingPathComponent("push-notices.json"))
        #expect(log().entries() == [.init(
            date: Date(timeIntervalSince1970: 1_800_000_000), why: .found, subscription: "0a80627d", count: 2,
            shown: .details)])
    }

    @Test(arguments: [Data(), Data(repeating: 0xFF, count: 300), Data(repeating: 0x5B, count: 64)])
    func arbitraryBytesNeverCrash(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("push-notices.json"))
        _ = log().entries()
    }

    @Test func theFingerprintIsTheRelays() {
        // The relay logs the first 8 hex digits of the subscription id's SHA-256 (relay
        // internal/api/push.go); the same value lets a push be followed across both logs.
        #expect(PushNoticeLog.fingerprint("sub-1") == "0a80627d")
    }

    @Test func entriesFromBeforeTheDetailsStillRead() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"[{"date":1800000000,"why":"found"}]"#.utf8)
            .write(to: folder.appendingPathComponent("push-notices.json"))
        #expect(log().entries() == [.init(date: Date(timeIntervalSince1970: 1_800_000_000), why: .found)])
    }

    /// Notes from before the journal show only as long as the journal keeps its own.
    @Test func onlyNotesSinceADateAreListed() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"[{"date":1800000000,"why":"found"},{"date":1800100000,"why":"nothingNew"}]"#.utf8)
            .write(to: folder.appendingPathComponent("push-notices.json"))
        let lines = log().lines(since: Date(timeIntervalSince1970: 1_800_050_000))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("nothingNew") == true)
    }
}

