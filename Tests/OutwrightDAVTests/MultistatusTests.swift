// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

@Suite struct MultistatusTests {
    @Test func readsResponsesPropstatsAndSyncToken() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
              <D:response>
                <D:href>/books/work/</D:href>
                <D:propstat>
                  <D:prop>
                    <D:displayname>Work &amp; friends</D:displayname>
                    <D:current-user-principal><D:href>/principals/jk/</D:href></D:current-user-principal>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
                <D:propstat>
                  <D:prop><CS:getctag/></D:prop>
                  <D:status>HTTP/1.1 404 Not Found</D:status>
                </D:propstat>
              </D:response>
              <D:response>
                <D:href>/books/work/gone.vcf</D:href>
                <D:status>HTTP/1.1 404 Not Found</D:status>
              </D:response>
              <D:sync-token>http://example.org/sync/7</D:sync-token>
            </D:multistatus>
            """
        let status = try Multistatus.parse(Data(xml.utf8))
        #expect(status.responses.count == 2)
        #expect(status.syncToken == "http://example.org/sync/7")
        let first = try #require(status.responses.first)
        #expect(first.href == "/books/work/")
        #expect(first.property(.dav("displayname"))?.text == "Work & friends")
        #expect(first.property(.dav("current-user-principal"))?.hrefs == ["/principals/jk/"])
        #expect(first.property(QName(namespace: DAVNamespace.calendarServer, name: "getctag")) == nil)
        #expect(first.propstats.map(\.status) == [200, 404])
        let second = try #require(status.responses.last)
        #expect(second.href == "/books/work/gone.vcf")
        #expect(second.status == 404)
        #expect(second.propstats.isEmpty)
    }

    @Test func readsCalendarColorAndComponentSet() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" \
            xmlns:I="http://apple.com/ns/ical/">
              <D:response>
                <D:href>/cal/work/</D:href>
                <D:propstat>
                  <D:prop>
                    <I:calendar-color>#D04A2FFF</I:calendar-color>
                    <C:supported-calendar-component-set>
                      <C:comp name="VEVENT"/><C:comp name="VTODO"/>
                    </C:supported-calendar-component-set>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """
        let status = try Multistatus.parse(Data(xml.utf8))
        let response = try #require(status.responses.first)
        let color = QName(namespace: DAVNamespace.appleICal, name: "calendar-color")
        #expect(response.property(color)?.text == "#D04A2FFF")
        let components = response.property(.calDAV("supported-calendar-component-set"))
        #expect(components?.nameAttributes == ["VEVENT", "VTODO"])
        #expect(components?.descendants == [.calDAV("comp")])
    }

    @Test func componentNamesAreCapped() throws {
        let cap = DAVLimits.multistatusNameAttributes
        let comps = String(repeating: "<c:comp name=\"VEVENT\"/>", count: cap + 1)
        let xml = """
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/a/</d:href>\
            <d:propstat><d:prop><c:supported-calendar-component-set>\(comps)</c:supported-calendar-component-set>\
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """
        let status = try Multistatus.parse(Data(xml.utf8))
        let property = try #require(status.responses.first?.property(.calDAV("supported-calendar-component-set")))
        #expect(property.nameAttributes.count == cap)
    }

    func check(_ data: Data) {
        do {
            let status = try Multistatus.parse(data)
            #expect(status.responses.count <= DAVLimits.multistatusResponses)
        } catch {
            #expect(error == .malformed || error == .tooLarge)
        }
    }

    @Test func parserNeverTrapsOverArbitraryBytes() {
        var rng = SeededGenerator(state: 99)
        for _ in 0..<2_000 {
            let count = Int.random(in: 0...4096, using: &rng)
            check(rng.bytes(count))
        }
        let fixture = Data("""
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/a/</d:href><d:propstat><d:prop>\
            <d:getetag>"1"</d:getetag><d:resourcetype><d:collection/></d:resourcetype>\
            <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/>\
            </c:supported-calendar-component-set></d:prop>\
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>\
            <d:sync-token>t</d:sync-token></d:multistatus>
            """.utf8)
        for cut in stride(from: 0, to: fixture.count, by: 2) { check(fixture.prefix(cut)) }
        for _ in 0..<3_000 {
            var copy = fixture
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                copy[Int.random(in: 0..<copy.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            check(copy)
        }
        let deep = String(repeating: "<d:prop>", count: 10_000)
        check(Data("<d:multistatus xmlns:d=\"DAV:\"><d:response>\(deep)".utf8))
        let many = String(repeating: "<d:response><d:href>/x</d:href></d:response>", count: 60_000)
        let manyData = Data("<d:multistatus xmlns:d=\"DAV:\">\(many)</d:multistatus>".utf8)
        check(manyData)
        #expect(throws: DAVError.tooLarge) { try Multistatus.parse(manyData) }
        let laughs = """
            <?xml version="1.0"?><!DOCTYPE m [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">\
            <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><d:multistatus xmlns:d="DAV:">\
            <d:sync-token>&c;</d:sync-token></d:multistatus>
            """
        check(Data(laughs.utf8))
        check(Data(laughs.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
    }
}
