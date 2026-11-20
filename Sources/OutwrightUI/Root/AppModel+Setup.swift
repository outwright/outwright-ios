// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
public import OutwrightSetup
public import OutwrightSync

#if canImport(UIKit)
    import UIKit
#endif

/// The setup file: what this build carries in it.
extension AppModel {
    /// The exchange that makes and restores a setup file from the open parts (accounts and
    /// subscribed calendars) and the ones the modules register. The app's settings stay on each
    /// device.
    public func setupExchange(parameters: Argon2Parameters = .writer) -> SetupExchange {
        let providers = ProviderSet([OwnServerProvider()] + modules.providers)
        let open: [any SetupPart] = [
            AccountsSetupPart(
                store: store, secrets: sync.secrets, providers: providers,
                pushEnabled: { [push] account in await push?.switcher.isEnabled(account) ?? false },
                lastError: { [sync] account in await sync.lastErrors[account] },
                signatures: DefaultSignature.setupRule, title: L10n.string("Accounts")),
            SubscriptionsSetupPart(store: store, secrets: sync.secrets, title: L10n.string("Subscribed calendars"))
        ]
        return SetupExchange(
            parts: open + modules.setupParts, device: Self.deviceName, parameters: parameters, secrets: sync.secrets)
    }

    /// The model of a backup, a move or a restore, unlocking with the device's own lock.
    func setupModel() -> SetupModel {
        let store = store
        let reminders = sync.reminders
        let ask: @Sendable () async -> Bool
        if let push {
            ask = push.askPermission
        } else {
            ask = { await reminders.requestAuthorization() }
        }
        let notices = SetupNotices(
            anyOn: {
                let accounts = (try? store.accounts()) ?? []
                return accounts.contains { account in (try? store.notifiesNewMail(account.id)) == true }
            },
            ask: ask)
        return SetupModel(
            exchange: setupExchange(), unlock: SystemDeviceUnlock(), notices: notices,
            phoneContacts: phoneContactsForSetup())
    }

    /// The model of sending the setup straight to another device, unlocking with the device's own lock.
    func sendSetupModel() -> SendSetupModel {
        SendSetupModel(exchange: setupExchange(), unlock: SystemDeviceUnlock())
    }

    /// The model of receiving the setup straight from another device: restored as a file is, and
    /// the accounts it added read and watched at once.
    func receiveSetupModel() -> ReceiveSetupModel {
        ReceiveSetupModel(
            setup: setupModel(), device: Self.deviceName,
            restored: { [weak self] in await self?.restoredFromSetup() })
    }

    /// Restored accounts with saving their contacts to the phone on: access is asked for, and
    /// refused, the switch goes off for them (as turning it on in the account's settings does).
    func phoneContactsForSetup() -> SetupPhoneContacts {
        let store = store
        let sync = sync
        @Sendable func saving(_ items: [SetupItem]) -> [Account] {
            let addresses = Set(items.map { $0.label.lowercased() })
            return ((try? store.accounts()) ?? []).filter {
                $0.savesContactsToPhone && addresses.contains($0.email.lowercased())
            }
        }
        return SetupPhoneContacts(
            saving: { items in saving(items).map { SetupItem(kind: .account, label: $0.email) } },
            ask: { await sync.requestPhoneAccess() },
            turnOff: { items in
                var off: [SetupItem] = []
                for var account in saving(items) {
                    account.savesContactsToPhone = false
                    guard (try? store.save(account)) != nil else { continue }
                    off.append(SetupItem(kind: .account, label: account.email))
                }
                return off
            })
    }

    /// A setup file was opened from elsewhere. It replaces the first-run screen, which closes for
    /// it; over another sheet it waits until that sheet is closed.
    public func openSetupFile(_ url: URL) {
        let request = SetupFileRequest(url: url)
        // The newer file takes the place of one still waiting, whose handed-over copy goes.
        if let waiting = pendingSetupFile { SetupModel.discardHandedOver(waiting.url) }
        if isAddingAccount, addingFirstAccount, !firstRunHeld {
            pendingSetupFile = request
            isAddingAccount = false
        } else if isPresenting || eventToShow != nil {
            pendingSetupFile = request
        } else {
            setupFileToOpen = request
        }
    }

    /// Removes the handed-over setup files no restore will open, keeping the one showing and the one
    /// waiting. Also when the app goes to the background, so a file left by an app closed before or
    /// during its restore does not linger.
    public func sweepSetupFiles(inbox: URL? = SetupModel.handedOverFolder) {
        let waiting = [setupFileToOpen, pendingSetupFile].compactMap { $0?.url }
        SetupModel.sweepHandedOver(inbox: inbox, keeping: waiting)
    }

    /// The restore sheet closed: what waited for it opens, and with still no account the first
    /// run opens as it would have at launch. Handed-over setup files no restore will open are swept
    /// then, keeping the ones still to be restored; `inbox` is where iOS puts them.
    func setupFileClosed(inbox: URL? = SetupModel.handedOverFolder) {
        openPending()
        sweepSetupFiles(inbox: inbox)
        guard setupFileToOpen == nil, pendingSetupFile == nil, !isAddingAccount else { return }
        if let stored = try? store.accounts(), stored.isEmpty { isAddingAccount = true }
    }

    /// Accounts were restored from a setup file: they show at once, as a new account does. Their
    /// notifications came with them.
    public func restoredFromSetup() async {
        reloadAccounts()
        await accountsArrived()
    }

    /// An account was just added: it shows at once (`accountsArrived`), its Inbox bodies prefetched
    /// so an invitation in it reaches the calendar now. Its notifications are switched on first, as
    /// the switch in its settings would: push where its host offers it, local notices otherwise. A
    /// refused permission leaves them off.
    public func accountAdded(_ account: Account) async {
        reloadAccounts()
        await switchNotificationsOn(account)
        await accountsArrived()
    }

    /// Accounts came (added or restored): their Inboxes say mail is on its way, they are watched and
    /// their contacts and calendars synced at once, then every folder is read and the Inbox bodies
    /// are prefetched on Wi-Fi.
    func accountsArrived() async {
        await updateFirstSync()
        await sceneChanged(toActive: true, onWiFi: onWiFi).value
        await refresh()
        await sync.prefetchInboxBodies(onWiFi: await onWiFi())
    }

    /// This device's name, written in the file so the owner knows where it came from.
    static var deviceName: String {
        #if canImport(UIKit)
            UIDevice.current.name
        #else
            ProcessInfo.processInfo.hostName
        #endif
    }
}

/// A setup file to restore.
struct SetupFileRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
