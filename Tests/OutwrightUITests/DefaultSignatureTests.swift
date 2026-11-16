// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import OutwrightStore
import Testing

@testable import OutwrightUI

@MainActor
struct DefaultSignatureTests {
    private func account(_ email: String, signature: String, order: Int) -> Account {
        let endpoint = MailEndpoint(host: "mail.example.org", port: 993, security: "tls")
        return Account(
            id: AccountID(), displayName: email, email: email, colorIndex: 0, imap: endpoint, smtp: endpoint,
            user: email, signature: signature, sortOrder: order)
    }

    @Test func anAccountWithoutASignatureGetsTheDefaultOnce() throws {
        let store = try MailStore(path: nil)
        let defaults = try #require(UserDefaults(suiteName: "signature-\(UUID().uuidString)"))
        let bare = account("a@example.org", signature: "", order: 0)
        let own = account("b@example.org", signature: "Anna", order: 1)
        try store.save(bare)
        try store.save(own)

        DefaultSignature.fillEmpty(store: store, defaults: defaults)
        let filled = try store.accounts()
        #expect(filled.first { $0.id == bare.id }?.signature == DefaultSignature.text)
        #expect(filled.first { $0.id == own.id }?.signature == "Anna")

        // The owner clears it afterwards: it stays cleared.
        var cleared = try #require(filled.first { $0.id == bare.id })
        cleared.signature = ""
        try store.save(cleared)
        DefaultSignature.fillEmpty(store: store, defaults: defaults)
        #expect(try store.accounts().first { $0.id == bare.id }?.signature == "")
    }

    @Test func theOldDefaultIsReplacedButAnOwnSignatureIsNot() throws {
        let store = try MailStore(path: nil)
        let english = account("a@example.org", signature: "Sent from Outwright for iOS\nhttps://github.com/outwright/outwright-ios", order: 0)
        let swedish = account("b@example.org", signature: "Skickat från Outwright för iOS\nhttps://github.com/outwright/outwright-ios\n", order: 1)
        let own = account("c@example.org", signature: "Anna\nhttps://github.com/outwright/outwright-ios", order: 2)
        for each in [english, swedish, own] { try store.save(each) }

        DefaultSignature.replaceOld(store: store)
        let accounts = try store.accounts()
        #expect(accounts.first { $0.id == english.id }?.signature == DefaultSignature.text)
        #expect(accounts.first { $0.id == swedish.id }?.signature == DefaultSignature.text)
        #expect(accounts.first { $0.id == own.id }?.signature == own.signature)
    }
}
