// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightSetup

@Suite struct Argon2Tests {
    @Test func argon2idMatchesRFC9106() throws {
        let parameters = Argon2Parameters(passes: 3, lanes: 4, memoryExponent: 5)
        let tag = try Argon2id.derive(
            password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
            parameters: parameters, length: 32,
            secret: [UInt8](repeating: 3, count: 8), associatedData: [UInt8](repeating: 4, count: 12))
        #expect(tag == hexBytes("0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"))
    }

    @Test func argon2RefusesHugeMemory() throws {
        #expect(throws: SetupError.tooLarge) { try Argon2Parameters(passes: 3, lanes: 4, memoryExponent: 19).validated() }
        #expect(throws: SetupError.tooLarge) { try Argon2Parameters(passes: 11, lanes: 4, memoryExponent: 16).validated() }
        #expect(throws: SetupError.tooLarge) { try Argon2Parameters(passes: 3, lanes: 9, memoryExponent: 16).validated() }
        #expect(throws: SetupError.malformed) { try Argon2Parameters(passes: 3, lanes: 0, memoryExponent: 16).validated() }
        #expect(throws: SetupError.malformed) { try Argon2Parameters(passes: 0, lanes: 4, memoryExponent: 16).validated() }
        #expect(throws: SetupError.malformed) { try Argon2Parameters(passes: 3, lanes: 4, memoryExponent: 2).validated() }
        #expect(throws: SetupError.tooLarge) {
            try Argon2id.derive(password: [], salt: [UInt8](repeating: 0, count: 16),
                parameters: Argon2Parameters(passes: 3, lanes: 4, memoryExponent: 19), length: 32)
        }
        #expect(try Argon2Parameters.writer.validated() == Argon2Parameters.writer)
    }

    @Test func argon2SmallParametersAreDeterministic() throws {
        let parameters = Argon2Parameters(passes: 1, lanes: 2, memoryExponent: 4)
        let salt = [UInt8](repeating: 9, count: 16)
        let a = try Argon2id.derive(password: Array("pw".utf8), salt: salt, parameters: parameters, length: 32)
        let b = try Argon2id.derive(password: Array("pw".utf8), salt: salt, parameters: parameters, length: 32)
        var salt2 = salt
        salt2[0] ^= 1
        let c = try Argon2id.derive(password: Array("pw".utf8), salt: salt2, parameters: parameters, length: 32)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 32)
    }

    @Test func argon2LongOutputsWork() throws {
        let parameters = Argon2Parameters(passes: 1, lanes: 1, memoryExponent: 3)
        let out = try Argon2id.derive(password: [1], salt: [UInt8](repeating: 0, count: 8), parameters: parameters, length: 100)
        #expect(out.count == 100)
    }
}

@Suite struct Argon2ParameterPropertyTests {
    @Test func validatedNeverAcceptsOutOfRangeValues() {
        // Every lanes and exponent value, with the passes values around the cap and the extremes.
        for passes in [0, 1, 2, 3, 9, 10, 11, 12, 128, 255] as [UInt8] {
            for lanes in UInt8.min...UInt8.max {
                for exponent in UInt8.min...UInt8.max {
                    let parameters = Argon2Parameters(passes: passes, lanes: lanes, memoryExponent: exponent)
                    guard let accepted = try? parameters.validated() else { continue }
                    #expect(accepted == parameters)
                    #expect((1...10).contains(passes))
                    #expect((1...8).contains(lanes))
                    #expect(exponent <= 18)
                    #expect((1 << Int(exponent)) >= 8 * Int(lanes))
                }
            }
        }
    }
}
