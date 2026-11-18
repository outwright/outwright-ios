// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightSetup

@Suite struct PairingCodeTests {
    /// The text of a code whose binary is `binary`, as a newer or broken writer would make it.
    static func text(of binary: [UInt8]) -> String {
        "OWSETUP:"
            + Data(binary).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func codeRoundTripsThroughText() throws {
        let code = PairingCode.generate(role: .sends, device: "Anna’s iPhone")
        #expect(code.version == 1)
        #expect(code.secret.count == 32)
        #expect(code.service.count == 12)
        #expect(code.service.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(code.text.hasPrefix("OWSETUP:"))
        #expect(try PairingCode(text: code.text) == code)
        #expect(PairingCode.generate(role: .sends, device: "x").secret != code.secret)
    }

    @Test func codeCutsALongDeviceNameAtACharacter() throws {
        let name = String(repeating: "ö", count: 50)  // 100 octets
        let code = PairingCode.generate(role: .receives, device: name)
        #expect(code.device.utf8.count <= 64)
        #expect(name.hasPrefix(code.device))
        let read = try PairingCode(text: code.text)
        #expect(read.device == code.device)
        #expect(String(validating: Array(read.device.utf8), as: UTF8.self) != nil)
    }

    @Test func codeReadsTheDeviceNameCleaned() throws {
        var code = PairingCode.generate(role: .sends, device: "x")
        code.device = "Anna\u{202E}enohp\u{0007}\u{200F}"
        #expect(try PairingCode(text: code.text).device == "Annaenohp")
        code.device = "\u{0000}\u{202D}"
        #expect(try PairingCode(text: code.text).device == "")
    }

    @Test func codeNeverShowsItsSecret() {
        let code = PairingCode.generate(role: .sends, device: "x")
        let hex = code.secret.map { String(format: "%02x", $0) }.joined()
        var dumped = ""
        dump(code, to: &dumped)
        for shown in [String(describing: code), String(reflecting: code), "\(code)", dumped] {
            #expect(!shown.contains(hex))
            #expect(!shown.contains("\(code.secret)"))
            #expect(!shown.contains("\(code.secret.first ?? 0), \(code.secret.dropFirst().first ?? 0)"))
        }
    }

    @Test func codeRefusesNewerVersion() throws {
        var binary = PairingCode.generate(role: .sends, device: "x").binary
        binary[0] = 2
        #expect(throws: SetupError.unsupported) { try PairingCode(text: Self.text(of: binary)) }
        #expect(throws: SetupError.unsupported) { try PairingCode(text: Self.text(of: [9])) }
    }

    @Test func codeRefusesOtherQRText() {
        #expect(throws: SetupError.malformed) { try PairingCode(text: "https://example.org") }
        #expect(throws: SetupError.malformed) { try PairingCode(text: "OWSETUP:") }
        #expect(throws: SetupError.malformed) { try PairingCode(text: "OWSETUP:a+b/") }
        let long = PairingCode.generate(role: .sends, device: "x").text + String(repeating: "A", count: 300)
        #expect(throws: SetupError.malformed) { try PairingCode(text: long) }
    }

    @Test func codeRefusesBrokenFields() {
        let code = PairingCode.generate(role: .sends, device: "x")
        var badRole = code.binary
        badRole[1] = 3
        var trailing = code.binary
        trailing.append(0)
        var invalidName = code.binary
        invalidName[invalidName.count - 1] = 0xFF
        var otherService = code
        var services: [[UInt8]] = []
        for service in ["ABCDEF123456", "abcdef12345", "abcdef1234567", "abcdefg12345", "abc def12345", ""] {
            otherService.service = service
            services.append(otherService.binary)
        }
        for binary in [badRole, trailing, invalidName, Array(code.binary.dropLast()), [0], []] + services {
            #expect(throws: SetupError.malformed) { try PairingCode(text: Self.text(of: binary)) }
        }
    }

    @Test func codeReadsArbitraryTextWithoutCrashing() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("OWSETUP:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+/=ö\u{0} ")
        for _ in 0..<2000 {
            let length = Int.random(in: 0..<300, using: &generator)
            let random = String((0..<length).compactMap { _ in alphabet.randomElement(using: &generator) })
            let text = Bool.random(using: &generator) ? "OWSETUP:" + random : random
            do { _ = try PairingCode(text: text) } catch { _ = error as SetupError }
        }
        let valid = Array(PairingCode.generate(role: .receives, device: "Mutated").text)
        for _ in 0..<2000 {
            var mutated = valid
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<mutated.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: mutated.remove(at: index)
                case 1: mutated.insert(alphabet.randomElement(using: &generator) ?? "A", at: index)
                default: mutated[index] = alphabet.randomElement(using: &generator) ?? "A"
                }
                if mutated.isEmpty { mutated = valid }
            }
            do {
                let code = try PairingCode(text: String(mutated))
                #expect(code.secret.count == 32 && code.service.utf8.count <= 63 && code.device.utf8.count <= 64)
            } catch {
                _ = error as SetupError
            }
        }
    }
}
