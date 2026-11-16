// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightIMAP
public import OutwrightModel
public import OutwrightNet
import OutwrightSMTP

/// Whether an account's servers take its password: signs in to IMAP, then to SMTP, sending
/// nothing. Used before an account is saved, so a wrong password keeps nothing.
public enum AccountCheck {
    public static func signIn(_ account: Account, password: Secret) async throws(SyncError) {
        let secrets = InMemorySecretStore()
        try secrets.setPassword(password, for: account.id)
        var checked = account
        checked.auth = .password
        try await signIn(checked, credentials: CredentialProvider(secrets: secrets))
    }

    /// As `signIn(_:password:)`, with whatever `credentials` hold for the account (an OAuth
    /// account's tokens).
    public static func signIn(_ account: Account, credentials: CredentialProvider) async throws(SyncError) {
        guard let imapEndpoint = AccountSyncer.endpoint(account.imap) else {
            throw .imap(.net(.io("Unknown transport security")))
        }
        guard let smtpEndpoint = AccountSyncer.endpoint(account.smtp) else {
            throw .smtp(.net(.io("Unknown transport security")))
        }
        let client = try await credentials.connect(imapEndpoint, account: account)
        await client.logout()
        try await credentials.withSMTP(for: account) { credential async throws(SMTPError) in
            try await SMTPClient.signIn(via: smtpEndpoint, user: account.user, credential: credential)
        }
    }
}
