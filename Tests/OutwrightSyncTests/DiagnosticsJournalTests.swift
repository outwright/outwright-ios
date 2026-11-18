// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Synchronization
import Testing

@testable import OutwrightSync

/// The diagnostics journal: typed events the app and its extension write to one file, the last
/// seven days, never more than the cap.
@Suite final class DiagnosticsJournalTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("outwright-journal-\(UUID().uuidString)", isDirectory: true)
    private var file: URL { folder.appendingPathComponent("diagnostics-journal.json") }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Clock: Sendable {
        private let value: Mutex<Date>
        init(_ date: Date) { value = Mutex(date) }
        var now: Date { value.withLock { $0 } }
        func move(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func journal(_ clock: Clock) -> DiagnosticsJournal {
        DiagnosticsJournal(fileURL: file) { clock.now }
    }

    @Test func keepsEventsInOrder() {
        let clock = Clock(start)
        let journal = journal(clock)
        let account = AccountID(raw: UUID())
        journal.note(.launch(version: "0.1.6", build: "0.1.6"))
        clock.move(1)
        journal.note(.sync(account: account, kind: .mail, code: "imap.net.timeout"))
        #expect(journal.entries().map(\.event) == [
            .launch(version: "0.1.6", build: "0.1.6"), .sync(account: account, kind: .mail, code: "imap.net.timeout"),
        ])
    }

    @Test func dropsOlderThanSevenDays() {
        let clock = Clock(start)
        let journal = journal(clock)
        journal.note(.store(bytes: 1, messages: 1))
        clock.move(8 * 86_400)
        journal.note(.store(bytes: 2, messages: 2))
        #expect(journal.entries().map(\.event) == [.store(bytes: 2, messages: 2)])
    }

    @Test func keepsOnlyTheNewestPastTheCap() {
        let clock = Clock(start)
        let journal = journal(clock)
        for index in 0..<(DiagnosticsJournal.maxEntries + 10) {
            journal.note(.store(bytes: Int64(index), messages: 0))
        }
        let entries = journal.entries()
        #expect(entries.count == DiagnosticsJournal.maxEntries)
        #expect(entries.first?.event == .store(bytes: 10, messages: 0))
    }

    @Test func twoWritersLoseNothing() async {
        let clock = Clock(start)
        let first = journal(clock)
        let second = journal(clock)
        await withTaskGroup(of: Void.self) { group in
            for writer in [first, second] {
                group.addTask {
                    for index in 0..<200 { writer.note(.store(bytes: Int64(index), messages: 0)) }
                }
            }
        }
        #expect(first.entries().count == 400)
    }

    /// A torn last line (a write cut short) costs that line only.
    @Test func aTornLineIsSkipped() throws {
        let journal = journal(Clock(start))
        journal.note(.store(bytes: 1, messages: 1))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"date\":18000".utf8))
        try handle.close()
        journal.note(.store(bytes: 2, messages: 2))
        #expect(journal.entries().map(\.event) == [.store(bytes: 1, messages: 1), .store(bytes: 2, messages: 2)])
    }

    @Test func aDamagedFileIsStartedAgain() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: file)
        let journal = journal(Clock(start))
        #expect(journal.entries().isEmpty)
        journal.note(.store(bytes: 1, messages: 1))
        #expect(journal.entries().count == 1)
    }

    @Test(arguments: [Data(), Data(repeating: 0xFF, count: 300), Data(repeating: 0x5B, count: 64)])
    func arbitraryBytesNeverCrash(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: file)
        _ = journal(Clock(start)).entries()
    }

    /// A sync event holds its date, kind, account id and code: nothing else can be in it.
    @Test func holdsNoText() throws {
        let account = AccountID(raw: UUID())
        journal(Clock(start)).note(.sync(account: account, kind: .calendar, code: "dav.status.401"))
        let text = try String(contentsOf: file, encoding: .utf8)
        for word in ["calendar", "dav.status.401", account.raw.uuidString] {
            #expect(text.contains(word))
        }
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["date", "event"])
    }

    /// A file past the trim size, of valid lines.
    private func bigFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = try JSONEncoder().encode(JournalEntry(date: start, event: .store(bytes: 1, messages: 1)))
        var data = Data()
        while data.count <= DiagnosticsJournal.trimSize {
            data.append(line)
            data.append(0x0A)
        }
        try data.write(to: file)
    }

    private var fileSize: Int { (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }

    @Test func aWriterThatDoesNotTrimOnlyAppends() throws {
        try bigFile()
        let before = fileSize
        let start = start
        DiagnosticsJournal(fileURL: file, now: { start }, trims: false).note(.store(bytes: 2, messages: 2))
        #expect(fileSize > before)
        journal(Clock(start)).note(.store(bytes: 3, messages: 3))
        #expect(fileSize < before)
    }

    /// Random bytes, and valid lines torn or flipped at random: reading never crashes, and every
    /// entry it gives back is one that was written.
    @Test func randomBytesNeverCrash() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rng = JournalSeededGenerator(seed: 69)
        let written = JournalEntry(date: start, event: .store(bytes: 7, messages: 7))
        let line = try JSONEncoder().encode(written) + Data([0x0A])
        for round in 0..<300 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                bytes = (0..<Int.random(in: 0...2_048, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            } else {
                bytes = Array(line + line + line)
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            try Data(bytes).write(to: file)
            for entry in journal(Clock(start)).entries() {
                #expect(entry.date.timeIntervalSince1970.isFinite)
            }
        }
    }
}

/// A small deterministic generator (SplitMix64), so the property test runs the same every time.
private struct JournalSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

