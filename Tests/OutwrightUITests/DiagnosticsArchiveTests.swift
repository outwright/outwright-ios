// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

@Suite struct DiagnosticsArchiveTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func number(_ payload: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Int])?["n"]
    }

    @Test func keepsTheNewestFourteen() throws {
        let archive = DiagnosticsArchive(folder: try temporaryFolder())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<20 {
            archive.keep(Data("{\"n\":\(index)}".utf8), at: start.addingTimeInterval(Double(index)))
        }
        let recent = archive.recent()
        #expect(recent.count == 14)
        #expect(recent.first.flatMap(number) == 19)
        #expect(recent.last.flatMap(number) == 6)
    }

    @Test func payloadsKeptAtTheSameMomentAreAllKept() throws {
        let archive = DiagnosticsArchive(folder: try temporaryFolder())
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            archive.keep(Data("{\"n\":\(index)}".utf8), at: moment)
        }
        #expect(archive.recent().compactMap(number) == [2, 1, 0])
    }

    @Test func payloadsKeptTogetherFromManyThreadsAreAllKept() throws {
        let archive = DiagnosticsArchive(folder: try temporaryFolder())
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            archive.keep(Data("{\"n\":\(index)}".utf8), at: moment)
        }
        #expect(Set(archive.recent().compactMap(number)) == Set(0..<8))
    }

    @Test func dropsOversized() throws {
        let archive = DiagnosticsArchive(folder: try temporaryFolder())
        archive.keep(Data(count: (1 << 20) + 1), at: Date())
        #expect(archive.recent().isEmpty)
    }

    @Test func missingFolderIsEmpty() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "absent-\(UUID().uuidString)", isDirectory: true)
        #expect(DiagnosticsArchive(folder: folder).recent().isEmpty)
    }

    @Test func keepingCreatesAMissingFolder() throws {
        let folder = try temporaryFolder().appendingPathComponent("Diagnostics", isDirectory: true)
        let archive = DiagnosticsArchive(folder: folder)
        archive.keep(Data("{}".utf8), at: Date())
        #expect(archive.recent().count == 1)
    }

    @Test func arbitraryBytesNeverCrash() throws {
        let folder = try temporaryFolder()
        var generator = SeededGenerator(seed: 17)
        var valid = 0
        for index in 0..<200 {
            let count = Int.random(in: 0..<4096, using: &generator)
            let bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
            if (try? JSONSerialization.jsonObject(with: bytes)) != nil { valid += 1 }
            try bytes.write(to: folder.appendingPathComponent("\(1_000 + index).json"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("5000.json"))
        let recent = DiagnosticsArchive(folder: folder).recent()
        #expect(recent.count == min(valid + 1, 14))
        #expect(recent.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil })
    }
}

/// A small deterministic generator (SplitMix64), so a property test runs the same every time.
private struct SeededGenerator: RandomNumberGenerator {
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
