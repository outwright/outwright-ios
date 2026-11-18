// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import ImageIO
import OutwrightMIME
import OutwrightModel
import OutwrightStore
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

    private func photo(_ type: UTType) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "bin")
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor @Test func photosGetDistinctNames() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        let first = try photo(.jpeg)
        let second = try photo(.jpeg)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let taken = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await model.attachPhoto(first, type: .jpeg, at: taken) == nil)
        #expect(await model.attachPhoto(second, type: .jpeg, at: taken) == nil)
        let names = model.attachments.map(\.filename)
        #expect(names.count == 2)
        #expect(Set(names).count == 2)
        #expect(names.allSatisfy { $0.hasSuffix(".jpg") })
    }

    @MainActor @Test func heicIsSentAsJPEG() async throws {
        var box = try Mailbox()
        let anna = try box.addAccount("anna@example.org")
        let model = ComposeModel(request: ComposeRequest(kind: .new), store: box.store, accounts: [anna])
        let heic = try photo(.heic)
        defer { try? FileManager.default.removeItem(at: heic) }
        #expect(await model.attachPhoto(heic, type: .heic, at: Date()) == nil)
        let attached = try #require(model.attachments.first)
        #expect(attached.mimeType == "image/jpeg")
        #expect(attached.filename.hasSuffix(".jpg"))
        #expect(attached.data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }
}
