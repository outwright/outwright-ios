// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@Suite struct ProtectionRequirementTests {
    @Test func encryptUnsignedDecodesAndOldKindsStillDo() throws {
        let unsigned = ProtectionRequirement(
            protection: ProtectionID(raw: "p"), recipients: ["a@example.org"], plainChosen: false, kind: .encryptUnsigned)
        let back = try JSONDecoder().decode(ProtectionRequirement.self, from: JSONEncoder().encode(unsigned))
        #expect(back == unsigned)
        // A requirement kept before there were kinds has no "kind" key.
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(unsigned)) as? [String: Any])
        object["kind"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ProtectionRequirement.self, from: old).kind == .encrypt)
    }
}
