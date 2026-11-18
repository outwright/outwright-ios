// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightSetup

struct SetupBundleTests {
    let small = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 10)

    func bundle(version: Int = 1, parts: [String: SetupBundle.Part]? = nil) -> SetupBundle {
        SetupBundle(
            version: version, created: Date(timeIntervalSince1970: 1_800_000_000), device: "Test phone",
            parts: parts ?? [
                "accounts": .init(version: 1, content: Data("{\"a\":1}".utf8)),
                "keys": .init(version: 1, content: Data("{\"k\":2}".utf8)),
            ])
    }

    @Test func bundleRoundTripsThroughTheFile() throws {
        let pass = try Passphrase.generate()
        let original = bundle()
        let file = try original.sealed(passphrase: pass, parameters: small)
        #expect(try SetupBundle.opened(file, passphrase: pass) == original)
        let other = try Passphrase.generate()
        #expect(throws: SetupError.wrongPassphrase) { try SetupBundle.opened(file, passphrase: other) }
    }

    /// The device a bundle names is hostile: shown without control and format characters, cut, possibly empty.
    @Test func theDeviceIsShownCleanedAndCut() {
        var held = bundle()
        held.device = "Pat\u{202E}s\u{0007} phone"
        #expect(held.shownDevice == "Pats phone")
        held.device = String(repeating: "é", count: 500)
        #expect(held.shownDevice.utf8.count <= SetupBundle.maxTitle)
        #expect(!held.shownDevice.isEmpty)
        held.device = "\u{200B}\u{0000}"
        #expect(held.shownDevice == "")
    }

    @Test func openedRefusesNewerVersion() throws {
        let pass = try Passphrase.generate()
        let file = try bundle(version: 2).sealed(passphrase: pass, parameters: small)
        #expect(throws: SetupError.unsupported) { try SetupBundle.opened(file, passphrase: pass) }
    }

    @Test func openedRefusesTooManyParts() throws {
        let pass = try Passphrase.generate()
        var parts: [String: SetupBundle.Part] = [:]
        for index in 0..<65 { parts["p\(index)"] = .init(version: 1, content: Data()) }
        #expect(throws: SetupError.tooLarge) { try bundle(parts: parts).sealed(passphrase: pass, parameters: small) }
        // Sealed by a writer that did not check: the reader still refuses.
        let json = try JSONEncoder().encode(bundleJSON(parts))
        let file = Data(try SymmetricMessage.seal([UInt8](json), passphrase: [UInt8](pass.display.utf8), parameters: small))
        #expect(throws: SetupError.tooLarge) { try SetupBundle.opened(file, passphrase: pass) }
    }

    @Test func openedRefusesAPartOverTheCap() throws {
        let pass = try Passphrase.generate()
        let big = Data(count: SetupBundle.maxPartSize + 1)
        let parts = ["big": SetupBundle.Part(version: 1, content: big)]
        #expect(throws: SetupError.tooLarge) { try bundle(parts: parts).sealed(passphrase: pass, parameters: small) }
        let json = try JSONEncoder().encode(bundleJSON(parts))
        let file = Data(try SymmetricMessage.seal([UInt8](json), passphrase: [UInt8](pass.display.utf8), parameters: small))
        #expect(throws: SetupError.tooLarge) { try SetupBundle.opened(file, passphrase: pass) }
    }

    @Test func unknownPartsSurvive() throws {
        let pass = try Passphrase.generate()
        var parts = bundle().parts
        parts["future"] = .init(version: 9, content: Data("{}".utf8))
        let file = try bundle(parts: parts).sealed(passphrase: pass, parameters: small)
        #expect(try SetupBundle.opened(file, passphrase: pass).parts["future"]?.version == 9)
    }

    @Test func notJSONIsMalformed() throws {
        let pass = try Passphrase.generate()
        let file = Data(try SymmetricMessage.seal([1, 2, 3], passphrase: [UInt8](pass.display.utf8), parameters: small))
        #expect(throws: SetupError.malformed) { try SetupBundle.opened(file, passphrase: pass) }
    }

    @Test func openedOnlyThrowsSetupErrorOrReturnsABundle() throws {
        let pass = try Passphrase.generate()
        let documents: [String] = [
            "", "null", "[]", "42", "\"x\"", "{}",
            "{\"version\":\"1\",\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{}}",
            "{\"version\":99999999999999999999,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{}}",
            "{\"version\":-5,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{}}",
            "{\"version\":1,\"created\":\"yesterday\",\"device\":\"x\",\"parts\":{}}",
            "{\"version\":1,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":[]}",
            "{\"version\":1,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{\"a\":{\"version\":1,\"content\":\"!!!not base64\"}}}",
            "{\"version\":1,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{\"a\":{\"version\":1}}}",
            "{\"version\":1,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{\"a\":null}}",
            String(repeating: "[", count: 5000), String(repeating: "{\"a\":", count: 5000),
            "{\"version\":1,\"created\":\"2027-01-15T08:00:00Z\",\"device\":\"x\",\"parts\":{\"a\":{\"version\":1,\"content\":\"AAAA\"}}}",
        ]
        var inputs = documents.map { [UInt8]($0.utf8) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let length = Int.random(in: 0..<200, using: &generator)
            inputs.append((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
        for plain in inputs {
            let file = Data(try SymmetricMessage.seal(plain, passphrase: [UInt8](pass.display.utf8), parameters: small))
            do {
                let bundle = try SetupBundle.opened(file, passphrase: pass)
                #expect(bundle.version >= 1 && bundle.version <= SetupBundle.currentVersion)
            } catch {
                _ = error as SetupError
            }
        }
        // Arbitrary bytes that are not a message at all.
        for _ in 0..<40 {
            let junk = Data((0..<Int.random(in: 0..<300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            do { _ = try SetupBundle.opened(junk, passphrase: pass) } catch { _ = error as SetupError }
        }
    }

    /// A writer that keeps fractional seconds or an offset (Go's RFC 3339 with nanoseconds) is read.
    @Test func createdIsReadWithFractionalSecondsAndOffsets() throws {
        let pass = try Passphrase.generate()
        let dates = [
            "2027-01-15T08:00:00Z": 1_800_000_000.0, "2027-01-15T08:00:00.5Z": 1_800_000_000.5,
            "2027-01-15T08:00:00.123456789Z": 1_800_000_000.123, "2027-01-15T09:00:00+01:00": 1_800_000_000.0,
        ]
        for (text, expected) in dates {
            let json = #"{"version":1,"created":"\#(text)","device":"x","parts":{}}"#
            let file = Data(try SymmetricMessage.seal([UInt8](json.utf8), passphrase: [UInt8](pass.display.utf8), parameters: small))
            let created = try SetupBundle.opened(file, passphrase: pass).created.timeIntervalSince1970
            #expect(abs(created - expected) < 0.001, "\(text)")
        }
    }

    @Test func createdIsWrittenInWholeSeconds() throws {
        let pass = try Passphrase.generate()
        var original = bundle()
        original.created = Date(timeIntervalSince1970: 1_800_000_000.75)
        let file = try original.sealed(passphrase: pass, parameters: small)
        let plain = try SymmetricMessage.open([UInt8](file), passphrase: [UInt8](pass.display.utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any])
        let created = try #require(json["created"] as? String)
        #expect(!created.contains("."))
    }

    /// A part's title travels beside its version, for a reader that does not know the part.
    @Test func aPartsTitleRoundTrips() throws {
        let pass = try Passphrase.generate()
        let parts = ["future": SetupBundle.Part(version: 1, title: "Future things", content: Data("{}".utf8))]
        let file = try bundle(parts: parts).sealed(passphrase: pass, parameters: small)
        let opened = try SetupBundle.opened(file, passphrase: pass)
        #expect(opened.parts["future"]?.title == "Future things")
        #expect(opened.label(of: "future") == "Future things")
    }

    /// A title that is missing, empty, too long or holds control characters reads as the part's name.
    @Test func aHostileTitleReadsAsTheName() {
        let titles: [String?] = [nil, "", "\u{7}bell", String(repeating: "x", count: SetupBundle.maxTitle + 1)]
        for title in titles {
            let held = bundle(parts: ["future": SetupBundle.Part(version: 1, title: title, content: Data())])
            #expect(held.label(of: "future") == "future")
        }
        let long = String(repeating: "n", count: 10_000)
        let named = bundle(parts: [long: SetupBundle.Part(version: 1, content: Data())])
        #expect((named.label(of: long)?.utf8.count ?? .max) <= SetupBundle.maxTitle)
    }

    /// A few characters carrying thousands of combining marks are capped by their bytes.
    @Test func aTitleIsCappedByItsBytes() {
        let heavy = String(repeating: "a" + String(repeating: "\u{301}", count: 1_000), count: 4)
        #expect(heavy.count == 4)
        let held = bundle(parts: ["future": SetupBundle.Part(version: 1, title: heavy, content: Data())])
        #expect(held.label(of: "future") == "future")
        let named = bundle(parts: [heavy: SetupBundle.Part(version: 1, content: Data())])
        // Not one of its characters fits: there is nothing to show of it.
        #expect(named.label(of: heavy) == nil)
    }

    /// A name with control or format characters is never shown: there is no label, and the screens
    /// show their own placeholder.
    @Test func aHostileNameReadsAsThePlaceholder() {
        for name in ["bell\u{7}", "rtl\u{202E}gpj", ""] {
            let named = bundle(parts: [name: SetupBundle.Part(version: 1, title: "\u{200B}", content: Data())])
            #expect(named.label(of: name) == nil)
        }
    }

    /// Encodes without the writer's checks, with the same date format.
    func bundleJSON(_ parts: [String: SetupBundle.Part]) -> [String: AnyEncodable] {
        [
            "version": .init(1), "created": .init("2027-01-15T08:00:00Z"), "device": .init("x"),
            "parts": .init(parts),
        ]
    }
}

struct AnyEncodable: Encodable {
    private let encode: @Sendable (any Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ value: T) { encode = { try value.encode(to: $0) } }
    func encode(to encoder: any Encoder) throws { try encode(encoder) }
}
