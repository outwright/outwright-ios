// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightModel
import OutwrightStore

extension ActionRunner {
    init(
        account: Account, store: MailStore, client: IMAPClient, secrets: any SecretStore, now: Date,
        folders: [Folder], protections: [any MailProtection] = [],
        mayContinue: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.init(
            account: account, store: store, client: client, credentials: CredentialProvider(secrets: secrets),
            now: now, folders: folders, protections: protections, mayContinue: mayContinue)
    }

    /// A send that ran is noted in the journal: a success, or its own refusal for good (which
    /// settles the send too), whether the server or the making ready refused it.
    func noteSend(_ pending: PendingAction, done: Bool) {
        guard case .send = pending.action, done else { return }
        journal?.note(.send(account: account.id, code: sendRefusalCode))
    }

    /// A send that failed is noted in the journal by its code.
    func noteSend(_ pending: PendingAction, failed error: SyncError) {
        guard case .send = pending.action else { return }
        journal?.note(.send(account: account.id, code: errorCode(error)))
    }
}
