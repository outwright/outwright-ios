// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// An account in the file that this device already has: updated with what the owner chose, or left
/// as it is when the owner left it off.
extension AccountsSetupPart {
    /// The accounts this device has, by address and by id; each one is updated once.
    struct Here {
        var byAddress: [String: Account]
        var byID: [AccountID: Account]
        var updated = Set<String>()
    }

    /// Handles an entry for an account left off or already here, and reports it; false for one to add.
    func importHere(
        _ entry: AccountEntry, here: inout Here, choices: SetupChoices, into report: inout SetupImportReport
    ) async -> Bool {
        let item = Self.item(entry.account)
        let address = entry.account.email.lowercased()
        // Left off: not added, and one already here is left as it is.
        if choices.leavingOff.contains(address) {
            report.skipped.append(SetupSkip(item: item, reason: .leftOff))
            return true
        }
        if let account = here.byAddress[address], here.updated.insert(address).inserted {
            await update(
                account, sameID: here.byID[entry.account.id] != nil, from: entry, replacing: choices.replacing,
                into: &report)
            return true
        }
        if let account = here.byID[entry.account.id] {
            fillSecret(of: account, from: entry, item: item, into: &report)
            return true
        }
        return false
    }

    /// An account already here by its address: its secret replaced when the owner chose the file's
    /// or filled in when it has none (the same id, as after a backup restored without its keychain),
    /// its servers when the owner chose the file's, and its signature taken where the rule says.
    /// Reported once: failed when the secret store or the store refused, replaced when anything was
    /// taken from the file, restored when the secret was filled in, already here otherwise.
    private func update(
        _ here: Account, sameID: Bool, from entry: AccountEntry, replacing: Set<String>,
        into report: inout SetupImportReport
    ) async {
        let item = Self.item(entry.account)
        let address = here.email.lowercased()
        var secret = SecretOutcome.none
        if replacing.contains(Self.passwordID(address)), let file = await replacement(for: here, from: entry) {
            secret = keep(file, for: here) ? .replaced : .failed
        } else if sameID {
            switch fillSecret(of: here, from: entry) {
            case true?: secret = .filled
            case false?: secret = .none
            case nil: secret = .failed
            }
        }
        var updated = here
        var taken = false
        if let servers = servers(for: here, file: entry.account, replacing: replacing) {
            updated = servers
            taken = true
        }
        if let signature = signature(for: here, file: entry.account, replacing: replacing) {
            updated.signature = signature
            taken = true
        }
        let saved = taken ? (try? store.save(updated)) != nil : nil
        // Once per account: failed, replaced, filled in, already here, in that order.
        if secret == .failed || saved == false {
            report.skipped.append(SetupSkip(item: item, reason: .failed))
        } else if secret == .replaced || saved == true {
            report.replaced.append(item)
        } else if secret == .filled {
            report.restored.append(item)
        } else {
            report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
        }
    }

    /// What became of an account's secret on an import.
    enum SecretOutcome { case none, replaced, filled, failed }

    /// Fills in the secret of an account already here, and reports what became of it.
    private func fillSecret(
        of here: Account, from entry: AccountEntry, item: SetupItem, into report: inout SetupImportReport
    ) {
        switch fillSecret(of: here, from: entry) {
        case true?: report.restored.append(item)
        case false?: report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
        case nil: report.skipped.append(SetupSkip(item: item, reason: .failed))
        }
    }

}
