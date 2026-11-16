// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import OutwrightUI

@Suite struct PickedPhotoTests {
    @Test func aPickedPhotoArrivesAsAFileOfItsOwn() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 64))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).png")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(for: .png, visibility: .all) { done in
            done(source, false, nil)
            return nil
        }
        let picked: PickedPhoto = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PickedPhoto.self) { continuation.resume(with: $0) }
        }
        defer { try? FileManager.default.removeItem(at: picked.url) }
        // The system's own copy goes when the import ends; the app's is in the temporary folder it clears.
        let folder = picked.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        #expect(folder == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL)
        #expect(picked.url != source)
        #expect(try Data(contentsOf: picked.url) == bytes, "the copy outlives the picker's own file")
    }
}
