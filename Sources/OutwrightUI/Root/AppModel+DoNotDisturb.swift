// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightModel
import OutwrightStore
public import OutwrightSync

extension AppModel {
    /// What is stored; one that has ended reads as off.
    public func doNotDisturb(defaults: UserDefaults = DoNotDisturbDefaults.shared) -> DoNotDisturb {
        let stored = DoNotDisturbDefaults.load(from: defaults)
        return stored.isActive(at: Date()) ? stored : DoNotDisturb()
    }

    /// The bell's choice: stored for the notifier and the notification extension, shown, and ended
    /// by itself when its time comes. The reminders already with the phone follow it.
    public func setDoNotDisturb(_ value: DoNotDisturb, defaults: UserDefaults = DoNotDisturbDefaults.shared) {
        DoNotDisturbDefaults.save(value, to: defaults)
        reloadDoNotDisturb(defaults: defaults)
        replanReminders()
    }

    /// Hands the phone the reminders again, quiet or loud as the bell now says.
    private func replanReminders() {
        let previous = doNotDisturbReplan
        let sync = sync
        doNotDisturbReplan = Task {
            await previous?.value
            await sync.rescheduleReminders()
        }
    }

    func reloadDoNotDisturb(defaults: UserDefaults = DoNotDisturbDefaults.shared) {
        doNotDisturbValue = doNotDisturb(defaults: defaults)
        doNotDisturbEnd?.cancel()
        guard let until = doNotDisturbValue.until else { return }
        doNotDisturbEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 0) + 0.5))
            guard !Task.isCancelled else { return }
            self?.reloadDoNotDisturb(defaults: defaults)
            self?.replanReminders()
        }
    }
}

extension AppModel {
    /// A new account's notifications go on at once, as its Notifications switch would put them.
    func switchNotificationsOn(_ account: Account) async {
        let reminders = sync.reminders
        let toggle = NotificationsToggleModel(
            account: account, support: push,
            local: StoreLocalNotifying(store: store) { await reminders.requestAuthorization() },
            pushIncluded: modules.offering?.includes(.push) ?? true)
        await toggle.set(true)
    }
}
