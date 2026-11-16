// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

enum Fixtures {
    static func data(_ s: String) -> Data {
        Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static let alternative = data("""
    From: =?ISO-8859-1?Q?J=F6rgen?= <J@Example.org>
    To: a@example.org, "Bo B" <bo@example.org>
    Subject: =?UTF-8?B?w4RyZW5kZQ==?=
    Date: Fri, 06 Nov 2026 10:00:00 +0100
    Message-ID: <m1@example.org>
    Content-Type: multipart/alternative; boundary="b1"

    --b1
    Content-Type: text/plain; charset=utf-8

    Hello plain
    --b1
    Content-Type: text/html; charset=utf-8

    <p>Hello html</p>
    --b1--
    """)

    static let mixed = data("""
    From: a@example.org
    To: b@example.org
    Subject: Faktura
    List-Unsubscribe: <mailto:u@example.org>
    In-Reply-To: <p1@example.org>
    References: <r1@example.org> <r2@example.org>
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/related; boundary="rel"

    --rel
    Content-Type: text/html; charset=utf-8

    <img src="cid:logo@example.org">
    --rel
    Content-Type: image/png
    Content-ID: <logo@example.org>
    Content-Disposition: inline
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --rel--
    --outer
    Content-Type: application/pdf
    Content-Disposition: attachment; filename*=UTF-8''r%C3%A4kning.pdf
    Content-Transfer-Encoding: base64

    JVBERi0=
    --outer
    Content-Type: text/calendar; method=REQUEST; charset=utf-8

    BEGIN:VCALENDAR
    METHOD:REQUEST
    END:VCALENDAR
    --outer--
    """)

    /// As Outlook sends an invitation: text, HTML and the calendar as alternatives.
    static let outlookInvitation = data("""
    From: Org <org@example.org>
    To: jk@example.org
    Subject: Planning
    Content-Type: multipart/alternative; boundary="alt"

    --alt
    Content-Type: text/plain; charset=utf-8

    Planning meeting
    --alt
    Content-Type: text/html; charset=utf-8

    <p>Planning meeting</p>
    --alt
    Content-Type: text/calendar; charset="utf-8"; method=REQUEST
    Content-Transfer-Encoding: base64

    QkVHSU46VkNBTEVOREFSDQpNRVRIT0Q6UkVRVUVTVA0KQkVHSU46VkVWRU5UDQpVSUQ6dTFAZXhh
    bXBsZS5vcmcNCkVORDpWRVZFTlQNCkVORDpWQ0FMRU5EQVINCg==
    --alt--
    """)

    /// An `.ics` file attached, its METHOD only in its body.
    static func icsAttachment(method: String) -> Data {
        data("""
        From: org@example.org
        To: jk@example.org
        Subject: Calendar
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain; charset=utf-8

        See the file
        --mix
        Content-Type: text/calendar; charset=utf-8; name="invite.ics"
        Content-Disposition: attachment; filename="invite.ics"

        BEGIN:VCALENDAR
        PRODID:-//Example//Example//EN
        METHOD:\(method)
        BEGIN:VEVENT
        UID:u2@example.org
        END:VEVENT
        END:VCALENDAR
        --mix--
        """)
    }
}
