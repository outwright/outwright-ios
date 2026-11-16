// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightMIME
public import OutwrightModel
public import OutwrightStore

extension ComposeModel {
    /// A model for the request, with the message it starts from read (and opened, which may
    /// decrypt) away from the main actor.
    public static func make(
        request: ComposeRequest, store: MailStore, accounts: [Account], accountInView: AccountID? = nil,
        locale: Locale = .current, now: @escaping () -> Date = { Date() },
        protectionUI: (any ProtectionUI)? = nil
    ) async -> ComposeModel {
        let opened = await startingMessage(request, store: store)
        return ComposeModel(
            request: request, store: store, accounts: accounts, accountInView: accountInView, locale: locale,
            now: now, protectionUI: protectionUI, opened: opened)
    }

    static func startingMessage(_ request: ComposeRequest, store: MailStore) async -> OpenedMessage? {
        let id: MessageID
        switch request.kind {
        case .reply(let message), .replyAll(let message), .forward(let message), .draft(let message): id = message
        case .new, .to, .diagnostics: return nil
        }
        return await Task.detached(priority: .userInitiated) { (try? store.opened(id)) ?? nil }.value
    }

    /// Whether the From shown is only the outer one of a decrypted mail, which anyone could write.
    static func fromIsForgeable(_ opened: OpenedMessage?) -> Bool {
        opened?.facts.map { $0.decryption == .decrypted && !$0.fromIsProtected } ?? false
    }
}
