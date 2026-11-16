// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightNet
public import OutwrightModel
public import OutwrightSync

/// Why a change to an account was not made.
public enum AccountSettingsError: Error, Sendable, Equatable {
    case keychain
    case store
    /// The servers did not take the password (or could not be reached); nothing was kept.
    case signIn(SyncError)
    /// The owner did not give Outwright access to the iPhone's Contacts.
    case contactsDenied
    /// The iPhone's Contacts refused a change.
    case phoneContacts
}

/// What of an account has not reached its server yet, and would be lost with it.
public struct UnsentWork: Equatable, Sendable {
    /// Queued changes other than messages to send: to mail, contacts and events.
    public var changes: Int
    /// Messages queued to be sent.
    public var messages: Int

    public var isEmpty: Bool { changes == 0 && messages == 0 }
}

extension AppModel {
    /// Forgets the account: switches its push off (while the password still reaches the mail
    /// server; a failure there does not stop the removal), then its password, then it and its
    /// mail on this phone (the server keeps everything), and the contacts it saved to the
    /// iPhone's Contacts. A folder of it in view gives way to every account's Inbox.
    public func removeAccount(_ id: AccountID) async throws(AccountSettingsError) {
        if let switcher = push?.switcher {
            try? await switcher.disable(id)
        }
        do {
            try sync.secrets.remove(for: id)
        } catch {
            throw .keychain
        }
        do {
            try store.removeAccount(id)
        } catch {
            throw .store
        }
        // The phone contacts made for it go too; what fails now goes on the next refresh.
        try? await sync.syncPhoneExport(id)
        // Its events are gone, so their reminders go from the phone.
        await sync.rescheduleReminders()
        if accountInView?.id == id {
            openAllInboxes()
        }
        reloadAccounts()
        if case .folder(let folder) = scope, store.findFolder(folder) == nil {
            openAllInboxes()
        }
    }

    /// What would be lost by removing the account now.
    public func unsentWork(of id: AccountID) -> UnsentWork {
        let pending = ((try? store.pendingActions()) ?? []).filter { $0.accountID == id }
        let messages = pending.filter {
            if case .send = $0.action { return true }
            return false
        }.count
        let changes = pending.count - messages + unsentContactChanges(of: id) + unsentEventChanges(of: id)
        return UnsentWork(changes: changes, messages: messages)
    }

    /// Checks the new password with both servers, then keeps it in the keychain in place of the old.
    public func changePassword(_ password: String, for account: Account) async throws(AccountSettingsError) {
        let secret = Secret(password)
        do {
            try await AccountCheck.signIn(account, password: secret)
        } catch {
            throw .signIn(error)
        }
        do {
            try sync.secrets.setPassword(secret, for: account.id)
        } catch {
            throw .keychain
        }
    }

    /// Saves the name and signature of an account already kept; the rest stays as stored.
    public func updateAccount(_ account: Account) throws(AccountSettingsError) {
        try changeStored(account.id) { stored in
            stored.displayName = account.displayName
            stored.signature = account.signature
        }
    }

    /// The owner said yes to the CardDAV address found outside the account's domain: it is used
    /// from the next synchronisation on.
    public func confirmCardDAV(_ account: AccountID) throws(AccountSettingsError) {
        try changeStored(account) { stored in
            guard let parked = stored.cardDAVUnconfirmed else { return }
            stored.cardDAV = parked
            stored.cardDAVUnconfirmed = nil
            stored.cardDAVOff = false
        }
    }

    /// The owner said no to the CardDAV address found outside the account's domain: no password goes
    /// there, and none is looked for again.
    public func declineCardDAV(_ account: AccountID) throws(AccountSettingsError) {
        try changeStored(account) { stored in
            stored.cardDAVUnconfirmed = nil
            stored.cardDAVOff = stored.cardDAV == nil
        }
        try clearContactsIfOff(account)
    }

    /// The CardDAV address the owner typed (blank: none, and none is looked for again). It replaces
    /// any address waiting to be confirmed. Without one the account's contacts go from this phone
    /// (the server keeps them), unsent changes with them: ask first (`unsentContactChanges`).
    public func setCardDAV(_ url: String?, for account: AccountID) throws(AccountSettingsError) {
        let typed = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try changeStored(account) { stored in
            // Off only when the owner blanked an address that was there.
            let hadOne = stored.cardDAV != nil || stored.cardDAVUnconfirmed != nil || stored.cardDAVOff
            stored.cardDAV = typed.isEmpty ? nil : typed
            stored.cardDAVUnconfirmed = nil
            stored.cardDAVOff = typed.isEmpty && hadOne
        }
        try clearContactsIfOff(account)
    }

    /// The account's contacts on or off (#60). Off: the CardDAV address unused, none looked for, and its
    /// contacts go from this phone (the server keeps them), unsent changes with them: ask first
    /// (`unsentContactChanges`). On: the address kept is used, or one is looked for on the next refresh.
    public func setContactsOn(_ isOn: Bool, for account: AccountID) async throws(AccountSettingsError) {
        try changeStored(account) { stored in
            // The address is kept, so turning it on again uses it; one waiting for a yes is dropped.
            if !isOn { stored.cardDAVUnconfirmed = nil }
            stored.cardDAVOff = !isOn
        }
        if isOn {
            await sync.lookForDAVAgain(.cardDAV, of: account)
        } else {
            try clearContactsIfOff(account)
        }
    }

    /// Contact changes of the account not on its server yet: lost if CardDAV is turned off now.
    public func unsentContactChanges(of id: AccountID) -> Int {
        (try? store.pendingContactChangeCount(id)) ?? 0
    }

    /// An account left without a CardDAV address, or with its contacts off, keeps no contacts here.
    private func clearContactsIfOff(_ id: AccountID) throws(AccountSettingsError) {
        guard let account = accounts.first(where: { $0.id == id }), account.cardDAV == nil || account.cardDAVOff
        else { return }
        do {
            try store.clearContacts(of: id)
        } catch {
            throw .store
        }
    }

    /// The owner said yes to the CalDAV address found outside the account's domain: it is used from
    /// the next synchronisation on.
    public func confirmCalDAV(_ account: AccountID) throws(AccountSettingsError) {
        try changeStored(account) { stored in
            guard let parked = stored.calDAVUnconfirmed else { return }
            stored.calDAV = parked
            stored.calDAVUnconfirmed = nil
            stored.calDAVOff = false
        }
    }

    /// The owner said no to the CalDAV address found outside the account's domain: no password goes
    /// there, and none is looked for again.
    public func declineCalDAV(_ account: AccountID) throws(AccountSettingsError) {
        try changeStored(account) { stored in
            stored.calDAVUnconfirmed = nil
            stored.calDAVOff = stored.calDAV == nil
        }
        try clearCalendarsIfOff(account)
    }

    /// The CalDAV address the owner typed (blank: none, and none is looked for again). It replaces any
    /// address waiting to be confirmed. Without one the account's calendars go from this phone (the
    /// server keeps them), unsent changes with them: ask first (`unsentEventChanges`).
    public func setCalDAV(_ url: String?, for account: AccountID) throws(AccountSettingsError) {
        let typed = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try changeStored(account) { stored in
            // Off only when the owner blanked an address that was there.
            let hadOne = stored.calDAV != nil || stored.calDAVUnconfirmed != nil || stored.calDAVOff
            stored.calDAV = typed.isEmpty ? nil : typed
            stored.calDAVUnconfirmed = nil
            stored.calDAVOff = typed.isEmpty && hadOne
        }
        try clearCalendarsIfOff(account)
    }

    /// The account's calendar on or off (#60), the same way as `setContactsOn`; ask first with
    /// `unsentEventChanges`.
    public func setCalendarOn(_ isOn: Bool, for account: AccountID) async throws(AccountSettingsError) {
        try changeStored(account) { stored in
            // The address is kept, so turning it on again uses it; one waiting for a yes is dropped.
            if !isOn { stored.calDAVUnconfirmed = nil }
            stored.calDAVOff = !isOn
        }
        if isOn {
            await sync.lookForDAVAgain(.calDAV, of: account)
        } else {
            try clearCalendarsIfOff(account)
        }
    }

    /// Event changes of the account not on its server yet: lost if CalDAV is turned off now.
    public func unsentEventChanges(of id: AccountID) -> Int {
        (try? store.pendingEventChangeCount(id)) ?? 0
    }

    /// An account left without a CalDAV address, or with its calendar off, keeps no calendars here.
    private func clearCalendarsIfOff(_ id: AccountID) throws(AccountSettingsError) {
        guard let account = accounts.first(where: { $0.id == id }), account.calDAV == nil || account.calDAVOff
        else { return }
        do {
            try store.clearCalendars(of: id)
        } catch {
            throw .store
        }
    }

    /// Syncs one account's calendars (after its CalDAV address changed), not its mail.
    public func refreshCalendars(_ account: AccountID) async {
        await sync.refreshCalendars(of: account)
        reloadAccounts()
        await updateSyncProblems()
    }

    /// The calendar new events go to.
    public var defaultCalendar: CalendarInfo? { try? store.defaultCalendar() }

    public func setDefaultCalendar(_ id: CalendarID) throws(AccountSettingsError) {
        do {
            try store.setDefaultCalendar(id)
        } catch {
            throw .store
        }
    }

    /// Turns saving the account's contacts to the iPhone's Contacts on (asking for access first;
    /// refused, it stays off) or off, which deletes the phone contacts Outwright made for it and
    /// nothing else. The copy is brought in step at once.
    public func setSavesContactsToPhone(
        _ isOn: Bool, for account: AccountID
    ) async throws(AccountSettingsError) {
        if isOn {
            guard await sync.requestPhoneAccess() else { throw .contactsDenied }
        }
        try changeStored(account) { $0.savesContactsToPhone = isOn }
        do {
            try await sync.syncPhoneExport(account)
        } catch {
            guard error == .phoneContactsDenied else { throw .phoneContacts }
            // Access was taken back since the question: the setting goes back off.
            if isOn { try? changeStored(account) { $0.savesContactsToPhone = false } }
            throw .contactsDenied
        }
    }

    /// Syncs one account's contacts (after its CardDAV address changed), not its mail.
    public func refreshContacts(_ account: AccountID) async {
        await sync.refreshContacts(of: account)
        reloadAccounts()
        await updateSyncProblems()
    }

    /// Changes the account as stored now (never a copy that may be behind), then reloads.
    private func changeStored(_ id: AccountID, _ change: (inout Account) -> Void) throws(AccountSettingsError) {
        let current: [Account]
        do {
            current = try store.accounts()
        } catch {
            throw .store
        }
        guard var account = current.first(where: { $0.id == id }) else { throw .store }
        change(&account)
        do {
            try store.save(account)
        } catch {
            throw .store
        }
        reloadAccounts()
        // The notification extension reads push's own copy of the account; it follows, in order.
        if let switcher = push?.switcher {
            let previous = pushRefresh
            let changed = account
            pushRefresh = Task {
                await previous?.value
                await switcher.accountChanged(changed)
            }
        }
    }
}
