// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
import Testing

@testable import OutwrightStore

@Suite struct FileStoreTests {
    @Test func readsGoOnWhileALongWriteRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MailStore(path: folder.appendingPathComponent("mail.sqlite"))
        try store.save(Fixture.makeAccount(name: "Anna", email: "anna@example.org", order: 0))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? store.write { _ in
                started.signal()
                Thread.sleep(forTimeInterval: 1)
            }
            finished.signal()
        }
        started.wait()
        let clock = ContinuousClock()
        let begun = clock.now
        let accounts = try store.accounts()
        let waited = clock.now - begun
        finished.wait()
        #expect(accounts.count == 1)
        #expect(waited < .milliseconds(500))
    }

    @Test func aBodyWithAnAttachmentDeepInsideMarksTheRow() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        let signed = """
            From: bo@example.org\r\nSubject: Signed\r\n\
            Content-Type: multipart/signed; boundary="outer"; protocol="application/pgp-signature"\r\n\r\n\
            --outer\r\nContent-Type: multipart/mixed; boundary="inner"\r\n\r\n\
            --inner\r\nContent-Type: text/plain\r\n\r\nSee the file.\r\n\
            --inner\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename="a.pdf"\r\n\
            Content-Transfer-Encoding: base64\r\n\r\nJVBERi0xLjQK\r\n--inner--\r\n\
            --outer\r\nContent-Type: application/pgp-signature\r\n\r\nsig\r\n--outer--\r\n
            """
        try f.store.setBody(Data(signed.utf8), for: id)
        #expect(try f.store.message(id)?.hasAttachment == true)
    }

    @Test func searchSkipsStylesScriptsAndTheHeadOfHTML() throws {
        let f = try Fixture()
        let id = try #require(try f.store.upsert([row(f.account.id, f.inbox.id, uid: 1)]).first)
        let html = """
            From: bo@example.org\r\nSubject: Hej\r\nContent-Type: text/html; charset=utf-8\r\n\r\n\
            <html><head><title>hiddentitle</title><style>.hiddenstyle{}</style></head>\
            <body><script>hiddenscript()</script><p>visibleword</p></body></html>\r\n
            """
        try f.store.setBody(Data(html.utf8), for: id)
        #expect(try f.store.search("visibleword", limit: 5).count == 1)
        for word in ["hiddentitle", "hiddenstyle", "hiddenscript"] {
            #expect(try f.store.search(word, limit: 5).isEmpty)
        }
    }
}
