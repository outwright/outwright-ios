// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightDAV
import OutwrightGraph
import OutwrightJMAP
import OutwrightIMAP
import OutwrightNet
import OutwrightSMTP
import Testing

@testable import OutwrightSync

/// An error's code names it, from the outermost case to the innermost, without anything a server
/// or a message put in it.
@Suite struct ErrorCodeTests {
    @Test func namesNestedCases() {
        #expect(errorCode(SyncError.imap(.net(.timeout))) == "imap.net.timeout")
    }

    @Test func keepsAStatusNumber() {
        #expect(errorCode(SyncError.dav(.status(401))) == "dav.status.401")
        #expect(errorCode(SyncError.smtp(.rejected(code: 550, text: "no such user bo@example.org"))) == "smtp.rejected.550")
    }

    @Test func dropsServerText() {
        #expect(errorCode(SyncError.imap(.no("a@b.example secret"))) == "imap.no")
        #expect(errorCode(SyncError.imap(.net(.io("x")))) == "imap.net.io")
        #expect(errorCode(SyncError.dav(.offDomainRedirect(host: "evil.example"))) == "dav.offDomainRedirect")
    }

    @Test func aPlainCase() {
        #expect(errorCode(SyncError.noPassword) == "noPassword")
    }

    /// An error that describes itself in words is still coded by its case names.
    @Test func casesThatDescribeThemselvesAreCodedByName() {
        #expect(errorCode(SyncError.oauth(.transport)) == "oauth.transport")
        #expect(errorCode(SyncError.oauth(.invalidGrant)) == "oauth.invalidGrant")
        #expect(errorCode(SyncError.oauth(.refused("invalid_client: secret"))) == "oauth.refused")
    }

    @Test func aKeychainStatusIsKept() {
        #expect(errorCode(SyncError.keychain(-25300)) == "keychain.-25300")
    }
}
