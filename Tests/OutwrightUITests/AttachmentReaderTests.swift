// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightUI

@Suite struct AttachmentReaderTests {
    private func file(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test func aFileWithinTheLimitIsReadWhole() throws {
        let url = try file(1_000)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AttachmentReader.read(url, limit: 1_000) == .read(Data(repeating: 0x41, count: 1_000)))
    }

    @Test func aFileOverTheLimitIsTooLarge() throws {
        let url = try file(1_001)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AttachmentReader.read(url, limit: 1_000) == .tooLarge)
    }

    @Test func noRoomLeftMakesAnyFileTooLarge() throws {
        let url = try file(1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AttachmentReader.read(url, limit: 0) == .tooLarge)
        #expect(AttachmentReader.read(url, limit: -5) == .tooLarge)
    }

    @Test func anEmptyFileIsReadAsEmpty() throws {
        let url = try file(0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AttachmentReader.read(url, limit: 1_000) == .read(Data()))
    }

    @Test func aMissingFileIsUnreadableNotTooLarge() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(AttachmentReader.read(url, limit: 1_000) == .unreadable)
    }
}
