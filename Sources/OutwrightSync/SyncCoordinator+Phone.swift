// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
import OutwrightStore

extension SyncCoordinator {
    /// Whether this coordinator can save contacts to the phone at all.
    public nonisolated var canSaveToPhone: Bool { phoneContacts != nil }

    /// Asks the owner for access to the phone's Contacts; false when refused or not possible.
    public func requestPhoneAccess() async -> Bool {
        await phoneContacts?.requestAccess() ?? false
    }

    /// Brings the phone's copy of the account's contacts in step with the store: saved, changed and
    /// removed for an account that saves to the phone; for one that doesn't (or no longer exists),
    /// every phone contact Outwright recorded for it is removed, then its group once empty, and
    /// nothing else. Runs without suspending, so two can't interleave. A contact that fails is tried
    /// again next time; the first failure is thrown once the rest are done. A refusal thrown here
    /// has been told, so the refreshes after it don't tell it again.
    public func syncPhoneExport(_ id: AccountID) throws(SyncError) {
        do {
            try exportToPhone(id)
            phoneDenialTold.remove(id)
        } catch {
            if error == .phoneContactsDenied { phoneDenialTold.insert(id) }
            throw error
        }
    }

    /// The export of a refresh: a refusal is returned once, until the export next succeeds or is
    /// asked for directly.
    func refreshPhoneExport(_ id: AccountID) -> SyncError? {
        do {
            try exportToPhone(id)
            phoneDenialTold.remove(id)
            return nil
        } catch {
            guard error == .phoneContactsDenied else { return error }
            return phoneDenialTold.insert(id).inserted ? error : nil
        }
    }

    /// Syncs the account's contacts (and the phone's copy) without touching its mail; a failure is
    /// recorded.
    public func refreshContacts(of id: AccountID) async {
        if let error = await refreshContacts(id) {
            record(id, error)
        }
    }

    private func exportToPhone(_ id: AccountID) throws(SyncError) {
        guard let phone = phoneContacts else {
            return
        }
        let account = try stored { try store.accounts() }.first { $0.id == id }
        let exported = try stored { try store.phoneExports(id) }
        let recordedGroup = try stored { try store.phoneExportGroup(id) }
        guard let account, account.savesContactsToPhone else {
            guard !exported.isEmpty || recordedGroup != nil else {
                return
            }
            try phone.remove(identifiers: exported.values.sorted(), group: recordedGroup)
            try stored { try store.clearPhoneExports(id) }
            try stored { try store.setPhoneExportGroup(nil, account: id) }
            return
        }
        try save(account, to: phone, exported: exported, recordedGroup: recordedGroup)
    }

    private func save(
        _ account: Account, to phone: any PhoneContacts, exported recorded: [ContactID: String],
        recordedGroup: String?
    ) throws(SyncError) {
        let id = account.id
        var exported = recorded
        let books = Set(try stored { try store.addressBooks(id) }.map(\.id))
        let wanted = try stored { try store.contacts(in: books, matching: nil) }
        let group = try phone.group(identifier: recordedGroup, name: account.email)
        if group.identifier != recordedGroup {
            try stored { try store.setPhoneExportGroup(group.identifier, account: id) }
        }
        let members = try phone.members(ofGroup: group.identifier)
        if group.adopted {
            let taken = try stored { try store.allPhoneExportIdentifiers() }
            let adopted = PhoneExport.adopt(members: members, wanted: wanted, exported: exported, taken: taken)
            for (contact, identifier) in adopted {
                exported[contact] = identifier
                try stored { try store.setPhoneExport(identifier, for: contact, account: id) }
            }
        }
        let inGroup = Set(members.map(\.identifier))
        let plan = PhoneExport.plan(exported: exported, wanted: wanted)
        var failure: SyncError?
        for (contact, identifier) in plan.upsert {
            do {
                let saved = try phone.upsert(
                    contact, identifier: identifier, group: group.identifier,
                    addToGroup: identifier.map { !inGroup.contains($0) } ?? true)
                if saved != identifier {
                    try stored { try store.setPhoneExport(saved, for: contact.id, account: id) }
                }
            } catch {
                guard error != .phoneContactsDenied else { throw error }
                failure = failure ?? error
            }
        }
        try removeStale(plan.remove, exported: exported, phone: phone, account: id)
        if let failure {
            throw failure
        }
    }

    private func removeStale(
        _ identifiers: [String], exported: [ContactID: String], phone: any PhoneContacts, account id: AccountID
    ) throws(SyncError) {
        guard !identifiers.isEmpty else {
            return
        }
        try phone.remove(identifiers: identifiers, group: nil)
        let gone = Set(identifiers)
        for (contact, identifier) in exported where gone.contains(identifier) {
            try stored { try store.setPhoneExport(nil, for: contact, account: id) }
        }
    }

    /// Removes the phone contacts of accounts no longer stored.
    func sweepPhoneExports() {
        guard phoneContacts != nil, let recorded = try? store.phoneExportAccounts(),
            let accounts = try? store.accounts()
        else {
            return
        }
        let stored = Set(accounts.map(\.id))
        for id in recorded where !stored.contains(id) {
            try? exportToPhone(id)
        }
    }

}
