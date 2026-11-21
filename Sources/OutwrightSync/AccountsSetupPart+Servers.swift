// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel

/// An account's servers and user name changed on one device: the owner chooses whether this one
/// takes them. Only these three fields; the account's id, mail and switches stay.
extension AccountsSetupPart {
    static func serversID(_ address: String) -> String { "servers:" + address }

    /// The servers of an account here and the file's, the same kind of account with the same
    /// provider, when they differ.
    func serversDifference(here: Account, file: Account) -> SetupDifference? {
        guard here.auth == file.auth, here.provider == file.provider else { return nil }
        let mine = Self.servers(of: here)
        let theirs = Self.servers(of: file)
        guard mine != theirs else { return nil }
        return SetupDifference(
            kind: .servers, part: name, label: file.email, id: Self.serversID(here.email.lowercased()),
            state: SetupDifference.state(here: mine, file: theirs))
    }

    /// The account here with the file's servers when the owner chose them; nil to keep its own.
    func servers(for here: Account, file: Account, replacing: Set<String>) -> Account? {
        guard replacing.contains(Self.serversID(here.email.lowercased())),
            serversDifference(here: here, file: file) != nil
        else { return nil }
        var updated = here
        updated.imap = file.imap
        updated.smtp = file.smtp
        updated.user = file.user
        return updated
    }

    /// The three fields as one text, to compare and to digest. A host name is the same in any
    /// case (RFC 4343); a user name is the server's to compare, so it is kept as typed.
    private static func servers(of account: Account) -> String {
        let endpoints = [account.imap, account.smtp].map {
            "\($0.host.lowercased())\u{0}\($0.port)\u{0}\($0.security)"
        }
        return (endpoints + [account.user]).joined(separator: "\u{1}")
    }
}
