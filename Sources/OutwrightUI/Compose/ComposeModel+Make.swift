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
        defaultAccount: AccountID? = nil, locale: Locale = .current, now: @escaping () -> Date = { Date() },
        protectionUI: (any ProtectionUI)? = nil, protectionScreens: [any ProtectionUI] = [],
        attachmentLimit: Int = ComposeModel.maxAttachmentBytes
    ) async -> ComposeModel {
        let opened = await startingMessage(request, store: store)
        return ComposeModel(
            request: request, store: store, accounts: accounts, accountInView: accountInView,
            defaultAccount: defaultAccount, locale: locale,
            now: now, protectionUI: protectionUI, protectionScreens: protectionScreens, opened: opened,
            attachmentLimit: attachmentLimit)
    }

    /// As `make`, for the compose sheet: a reply, forward or draft whose message has no body on the
    /// phone gets it with `fetchBody` first. When it still can't be read (not fetched, or a body that
    /// won't parse) a reply opens without the quote; a forward or draft is nil: compose never opens
    /// from the stored preview, which would forward, or save over the draft, a cut copy.
    public static func start(
        request: ComposeRequest, store: MailStore, accounts: [Account], accountInView: AccountID? = nil,
        defaultAccount: AccountID? = nil, locale: Locale = .current, now: @escaping () -> Date = { Date() },
        protectionUI: (any ProtectionUI)? = nil, protectionScreens: [any ProtectionUI] = [],
        fetchBody: @MainActor (MessageID) async -> Void
    ) async -> ComposeModel? {
        var opened = await startingMessage(request, store: store)
        if let id = request.startsFrom, opened == nil {
            guard (try? store.message(id)) != nil else { return nil }
            if ((try? store.body(id)) ?? nil) == nil { await fetchBody(id) }
            opened = await startingMessage(request, store: store)
            guard opened != nil || request.isReply else { return nil }
        }
        return ComposeModel(
            request: request, store: store, accounts: accounts, accountInView: accountInView,
            defaultAccount: defaultAccount, locale: locale,
            now: now, protectionUI: protectionUI, protectionScreens: protectionScreens, opened: opened,
            quotesOriginal: opened != nil || request.startsFrom == nil)
    }

    static func startingMessage(_ request: ComposeRequest, store: MailStore) async -> OpenedMessage? {
        guard let id = request.startsFrom else { return nil }
        return await Task.detached(priority: .userInitiated) { (try? store.opened(id)) ?? nil }.value
    }

    /// Whether the From shown is only the outer one of a decrypted mail, which anyone could write.
    static func fromIsForgeable(_ opened: OpenedMessage?) -> Bool {
        opened?.facts.map { $0.decryption == .decrypted && !$0.fromIsProtected } ?? false
    }
}

extension ComposeRequest {
    /// The stored message a reply, forward or draft starts from.
    var startsFrom: MessageID? {
        switch kind {
        case .reply(let message), .replyAll(let message), .forward(let message), .draft(let message): message
        case .new, .to, .people, .diagnostics: nil
        }
    }

    /// A reply or reply all.
    var isReply: Bool {
        switch kind {
        case .reply, .replyAll: true
        case .new, .to, .people, .diagnostics, .forward, .draft: false
        }
    }
}
