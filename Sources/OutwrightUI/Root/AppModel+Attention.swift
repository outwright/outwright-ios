// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// What needs the owner's attention, per account: sync problems, what the accounts themselves ask
/// (a contacts or calendar address outside the domain), and what the modules report.
extension AppModel {
    /// Every item of every account there is.
    public var attention: [AttentionItem] {
        let ids = Set(accounts.map(\.id))
        return reportedAttention.filter { ids.contains($0.account) } + accounts.flatMap(AttentionItem.davHosts)
    }

    /// The account's items; nil: every account's.
    public func attention(for account: AccountID?) -> [AttentionItem] {
        guard let account else { return attention }
        return attention.filter { $0.account == account }
    }

    /// What the tab in view shows: Mail the account in view's items (every account's in All
    /// accounts), Calendar and Contacts, which are of every account, every account's.
    public var attentionInView: [AttentionItem] {
        attention(for: selectedTab == .mail ? accountInView?.id : nil)
    }

    /// Looks again: the coordinator's last errors, then each module's report. A look that ends after a
    /// later one began keeps nothing, so an old answer never comes back over a newer one.
    public func updateAttention() async {
        attentionLooks &+= 1
        let look = attentionLooks
        await updateFirstSync()
        let errors = await sync.lastErrors
        let current = accounts
        let problems = current.compactMap { account in
            errors[account.id].map { AccountProblem(account: account, problem: SyncProblem($0)) }
        }
        var items = problems.map(AttentionItem.init)
        for module in modules.attention {
            items += await module.items(for: current)
        }
        guard look == attentionLooks else { return }
        syncProblems = problems
        reportedAttention = items
    }

    /// An item was tapped: Drafts, the provider's sign-in, or the account's settings.
    public func act(on item: AttentionItem) {
        switch item.action {
        case .drafts:
            isShowingSettings = false
            openDrafts(of: item.account)
        case .signInAgain:
            guard !signingIn.contains(item.account) else { return }
            guard let account = accounts.first(where: { $0.id == item.account }), let signIn = signIn(for: account)
            else {
                showSettings(account: item.account)
                return
            }
            signingIn.insert(account.id)
            Task {
                defer { signingIn.remove(account.id) }
                do throws(ProviderSignInError) {
                    try await signIn.signInAgain(account)
                } catch {
                    if case .failed(let text) = error { signInFailure = text }
                    return
                }
                await refresh()
            }
        case .accountSettings:
            showSettings(account: item.account)
        }
    }

    /// A banner's sign-in for the account is under way.
    public func isSigningIn(_ account: AccountID) -> Bool {
        signingIn.contains(account)
    }

    /// The account has a sign-in or password problem, which its password field puts right.
    func asksForPassword(_ account: AccountID) -> Bool {
        let ids = [AttentionItem.id(for: .signIn), AttentionItem.id(for: .noPassword)]
        return attention(for: account).contains { ids.contains($0.id) }
    }
}
