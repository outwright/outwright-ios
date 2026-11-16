// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct PhoneExportStoreTests {
    @Test func exportsAreRecordedReplacedAndCleared() throws {
        let f = try Fixture()
        let other = Fixture.makeAccount(name: "Bo", email: "bo@example.org", order: 1)
        try f.store.save(other)
        let first = ContactID(raw: 1)
        let second = ContactID(raw: 2)
        try f.store.setPhoneExport("phone-1", for: first, account: f.account.id)
        try f.store.setPhoneExport("phone-2", for: second, account: f.account.id)
        try f.store.setPhoneExport("phone-9", for: first, account: other.id)
        try f.store.setPhoneExport("phone-1b", for: first, account: f.account.id)
        #expect(try f.store.phoneExports(f.account.id) == [first: "phone-1b", second: "phone-2"])
        #expect(try f.store.phoneExportAccounts() == [f.account.id, other.id])

        try f.store.setPhoneExport(nil, for: second, account: f.account.id)
        #expect(try f.store.phoneExports(f.account.id) == [first: "phone-1b"])

        try f.store.clearPhoneExports(f.account.id)
        #expect(try f.store.phoneExports(f.account.id).isEmpty)
        #expect(try f.store.phoneExports(other.id) == [first: "phone-9"])
    }

    @Test func exportsOutliveTheAccountUntilCleared() throws {
        let f = try Fixture()
        try f.store.setPhoneExport("phone-1", for: ContactID(raw: 1), account: f.account.id)
        try f.store.removeAccount(f.account.id)
        #expect(try f.store.phoneExportAccounts() == [f.account.id])
        try f.store.clearPhoneExports(f.account.id)
        #expect(try f.store.phoneExportAccounts().isEmpty)
    }

    @Test func accountGroupIsRecordedAndCountsAsExported() throws {
        let f = try Fixture()
        #expect(try f.store.phoneExportGroup(f.account.id) == nil)
        try f.store.setPhoneExportGroup("group-1", account: f.account.id)
        #expect(try f.store.phoneExportGroup(f.account.id) == "group-1")
        #expect(try f.store.phoneExportAccounts() == [f.account.id])
        try f.store.setPhoneExportGroup(nil, account: f.account.id)
        #expect(try f.store.phoneExportGroup(f.account.id) == nil)
        #expect(try f.store.phoneExportAccounts().isEmpty)
    }

    @Test func ownersChoiceOfNoCardDAVIsKept() throws {
        let f = try Fixture()
        var account = f.account
        account.cardDAVOff = true
        try f.store.save(account)
        #expect(try f.store.accounts().first?.cardDAVOff == true)
        account.cardDAVOff = false
        try f.store.save(account)
        #expect(try f.store.accounts().first?.cardDAVOff == false)
    }
}
