// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
public import OutwrightModel
import OutwrightStore

extension SyncCoordinator {
    /// How far ahead reminders are planned.
    static let reminderHorizon: TimeInterval = 14 * 86_400

    /// Looks for the account's CalDAV address when it has none (once per process), then syncs its
    /// calendars and takes the invitations that waited for them. Returns the failure, if any.
    func refreshCalendars(_ id: AccountID) async -> SyncError? {
        guard !Task.isCancelled else {
            return nil
        }
        let discovery = await discoverCalDAV(id)
        do {
            try await calendarSyncer(for: id)?.sync()
        } catch {
            return discovery ?? error
        }
        // Invitations that came in before the calendars were listed go in now.
        await currentSyncers().first { $0.0 == id }?.1.retakeInvitations()
        return discovery
    }

    /// Syncs the account's calendars without touching its mail (after its CalDAV address changed); a
    /// failure is recorded. The reminders follow: a calendar turned off takes its reminders away, a
    /// new one brings its own.
    public func refreshCalendars(of id: AccountID) async {
        if let error = await refreshCalendars(id) {
            record(id, error)
        }
        await rescheduleReminders()
    }

    /// Hands the phone the reminders of the next two weeks (the nearest 64), when reminders are allowed.
    /// One reschedule at a time, each planned from the store when its turn comes: one that started
    /// earlier can never finish last with a plan the store has moved past.
    public func rescheduleReminders() async {
        let previous = reminderTurn
        let turn = Task {
            await previous?.value
            await self.planReminders()
        }
        reminderTurn = turn
        await turn.value
    }

    private func planReminders() async {
        guard await reminders.authorization() else {
            return
        }
        let start = now()
        let end = start.addingTimeInterval(Self.reminderHorizon)
        let held = (try? store.occurrences(from: start, to: end, in: nil)) ?? []
        await reminders.replace(ReminderPlan.plan(held, now: start))
    }

    /// The phone moved to another time zone: every event is laid out again for it, and the reminders
    /// follow.
    public func phoneZoneChanged() async {
        // `TimeZone.current` is cached until the system's zone is read again.
        NSTimeZone.resetSystemTimeZone()
        reexpand()
        await rescheduleReminders()
    }

    /// The phone's day changed (midnight): the events are laid out again for the window that moved
    /// with it, from the stored series, and the reminders follow. Nothing is fetched.
    public func dayChanged() async {
        reexpandIfNewDay()
        await rescheduleReminders()
    }

    /// Lays the events out again when the day has changed since they last were (the window moves with
    /// it), or the phone's zone is no longer the one they were laid out in (a move the app was not told
    /// of: floating events follow it all the same).
    func reexpandIfNewDay() {
        // `TimeZone.current` is cached until the system's zone is read again.
        NSTimeZone.resetSystemTimeZone()
        let zone = phoneZone()
        // Read from the store: a new start of the app (a background wake too) on the same day leaves
        // the layout alone, where one kept in memory would lay every event out at every start.
        if let last = try? store.laidOut(), last.day == CalendarWindow.day(now(), zone: zone),
            last.zone == zone.identifier {
            return
        }
        reexpand()
    }

    /// A failure notes nothing, so the next refresh tries again.
    private func reexpand() {
        let zone = phoneZone()
        let today = now()
        try? store.reexpandAll(
            window: CalendarWindow.window(now: today, zone: zone), phoneZone: zone,
            day: CalendarWindow.day(today, zone: zone))
    }

    /// The owner turned the account's calendar or contacts back on: its address is looked for again
    /// on the next refresh, even if it was looked for earlier in this run.
    public func lookForDAVAgain(_ service: DAVService, of id: AccountID) {
        switch service {
        case .calDAV: calDAVDiscoveryTried.remove(id)
        case .cardDAV: discoveryTried.remove(id)
        }
    }

    /// The silent discovery for an account with neither a confirmed nor a found address, unless the
    /// owner chose none. An address on the account's own domain or mail hosts is used; one elsewhere
    /// waits in `calDAVUnconfirmed` for the owner, and no password goes there. A save that fails is
    /// returned, and the account is looked at again on the next refresh.
    private func discoverCalDAV(_ id: AccountID) async -> SyncError? {
        guard !calDAVDiscoveryTried.contains(id), let account = storedCalendarAccount(id),
            account.calendarVia == .calDAV,
            account.calDAV == nil,
            account.calDAVUnconfirmed == nil, !account.calDAVOff
        else {
            return nil
        }
        calDAVDiscoveryTried.insert(id)
        guard let found = await DAVDiscovery.find(.calDAV, for: account, resolver: resolver, probe: probe),
            var current = storedCalendarAccount(id), current.calDAV == nil, current.calDAVUnconfirmed == nil,
            !current.calDAVOff
        else {
            return nil
        }
        if found.offDomain {
            current.calDAVUnconfirmed = found.url
        } else {
            current.calDAV = found.url
        }
        do {
            try store.save(current)
            return nil
        } catch {
            calDAVDiscoveryTried.remove(id)
            return .store(String(describing: error))
        }
    }

    private func storedCalendarAccount(_ id: AccountID) -> Account? {
        (try? store.accounts())?.first { $0.id == id && isAvailable($0) }
    }

    /// The account's calendar syncer (Graph or CalDAV, as the account's calendars come), made anew
    /// when its protocol, CalDAV address, sign-in, login, address or mail hosts changed (sharing the
    /// account's lock); nil for an account no longer stored, or over Graph with no Graph address.
    func calendarSyncer(for id: AccountID) async -> (any CalendarSyncing)? {
        guard let account = storedCalendarAccount(id) else {
            return nil
        }
        if let entry = calendarSyncers[id], Self.sameCalendars(entry.account, account) {
            return entry.syncer
        }
        let lock = locks[id] ?? AccountLock()
        locks[id] = lock
        let syncer: any CalendarSyncing
        if account.calendarVia == .graph {
            guard let base = graphBase(account) else { return nil }
            syncer = GraphCalendarSyncer(
                account: account, store: store, credentials: credentials, lock: lock, base: base,
                session: davSession, now: now, phoneZone: phoneZone)
        } else {
            syncer = CalendarSyncer(
                account: account, store: store, secrets: secrets, lock: lock, session: davSession, now: now,
                phoneZone: phoneZone, meetingWording: meetingWording)
        }
        let old = calendarSyncers[id]
        calendarSyncers[id] = (account, syncer)
        await old?.syncer.retire()
        return syncer
    }

    private static func sameCalendars(_ first: Account, _ second: Account) -> Bool {
        first.calDAV == second.calDAV && first.calDAVOff == second.calDAVOff
            && first.calendarVia == second.calendarVia && first.auth == second.auth
            && first.provider == second.provider && first.user == second.user
            && first.email == second.email
            && first.imap.host == second.imap.host && first.smtp.host == second.smtp.host
    }
}

/// What the coordinator asks of an account's calendar sync, CalDAV or Graph.
protocol CalendarSyncing: Actor {
    func sync() async throws(SyncError)
    func runChanges() async throws(SyncError)
    func retire()
}

extension CalendarSyncer: CalendarSyncing {}
extension GraphCalendarSyncer: CalendarSyncing {}
