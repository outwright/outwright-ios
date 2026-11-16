// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct ProtectionRequirementTests {
    func requirement(plain: Bool = false) -> ProtectionRequirement {
        ProtectionRequirement(
            protection: ProtectionID(raw: "test"), recipients: ["a@example.org", "b@example.org"], plainChosen: plain)
    }

    @Test func aRequirementIsKeptWithItsMessageAndCanBeCleared() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        #expect(try f.store.protection(of: id) == nil)
        try f.store.setProtection(requirement(plain: true), for: id)
        #expect(try f.store.protection(of: id) == requirement(plain: true))
        try f.store.setProtection(requirement(), for: id)
        #expect(try f.store.protection(of: id) == requirement())
        try f.store.setProtection(nil, for: id)
        #expect(try f.store.protection(of: id) == nil)
    }

    /// A requirement kept before signing existed asks for encryption, as it did then.
    @Test func aRequirementKeptBeforeKindsIsEncrypt() throws {
        let old = Data(#"{"protection":{"raw":"test"},"recipients":["a@example.org"],"plainChosen":false}"#.utf8)
        #expect(try JSONDecoder().decode(ProtectionRequirement.self, from: old).kind == .encrypt)
        let signed = ProtectionRequirement(
            protection: ProtectionID(raw: "test"), recipients: [], plainChosen: false, kind: .sign)
        let again = try JSONDecoder().decode(ProtectionRequirement.self, from: JSONEncoder().encode(signed))
        #expect(again == signed)
    }

    @Test func submittedAddressesAccumulateAndAreKept() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        #expect(try f.store.submittedTo(of: id).isEmpty)
        try f.store.addSubmitted(["A@example.org"], to: id)
        try f.store.addSubmitted(["b@example.org"], to: id)
        #expect(try f.store.submittedTo(of: id) == ["a@example.org", "b@example.org"])
    }
}
