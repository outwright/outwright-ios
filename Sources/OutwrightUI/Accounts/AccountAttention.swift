// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// Something wrong with an account that the owner should see wherever they are: on its avatar, in
/// the drawer, in Settings and as a banner on every tab.
public struct AttentionItem: Identifiable, Sendable, Hashable {
    /// Where a tap on the item goes.
    public enum Action: Sendable, Hashable {
        /// The account's settings, where the item is put right.
        case accountSettings
        /// The account's Drafts, where a message that wasn't sent waits.
        case drafts
        /// The provider's sign-in, once more.
        case signInAgain
        /// Nothing to put right: the owner has seen it, and it goes.
        case dismiss
    }

    /// Stable per source and kind, such as "openpgp.noKey"; the same for every account.
    public var id: String
    public var account: AccountID
    /// Already in the interface's language.
    public var text: String
    public var action: Action

    public init(id: String, account: AccountID, text: String, action: Action) {
        self.id = id
        self.account = account
        self.text = text
        self.action = action
    }
}

/// What a module reports about accounts, joined to the shared code at app start
/// (`Modules.attention`). The shared code shows what it gives and never names the module.
@MainActor public protocol AccountAttention: AnyObject {
    func items(for accounts: [Account]) async -> [AttentionItem]
}

extension AttentionItem {
    /// A sync problem: Drafts for a message that wasn't sent, the sign-in for a lost one, else the
    /// account's settings.
    init(_ problem: AccountProblem) {
        let action: Action =
            switch problem.problem {
            case .notSent: .drafts
            case .signInAgain: .signInAgain
            default: .accountSettings
            }
        self.init(
            id: Self.id(for: problem.problem), account: problem.account.id, text: problem.problem.reason,
            action: action)
    }

    static func id(for problem: SyncProblem) -> String {
        "sync.\(problem)"
    }

    /// The question of an account whose contacts or calendar were found outside its domain.
    @MainActor static func davHosts(of account: Account) -> [AttentionItem] {
        let domain = AddAccountModel.domain(of: account.email) ?? account.email
        var items: [AttentionItem] = []
        if account.contactsVia == .cardDAV, !account.cardDAVOff, let parked = account.cardDAVUnconfirmed {
            let text = String(
                format: L10n.string("The contacts are at %@, not at %@."), AccountSettingsView.host(of: parked), domain)
            items.append(
                AttentionItem(id: "dav.contactsHost", account: account.id, text: text, action: .accountSettings))
        }
        if account.calendarVia == .calDAV, !account.calDAVOff, let parked = account.calDAVUnconfirmed {
            let text = String(
                format: L10n.string("The calendar is at %@, not at %@."), AccountSettingsView.host(of: parked), domain)
            items.append(
                AttentionItem(id: "dav.calendarHost", account: account.id, text: text, action: .accountSettings))
        }
        return items
    }
}
