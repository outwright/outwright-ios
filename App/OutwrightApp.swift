// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Combine
import Foundation
import Network
import OutwrightMIME
import OutwrightModel
import OutwrightStore
import OutwrightSync
import OutwrightUI
import Synchronization
import SwiftUI
import UserNotifications

@main
struct OutwrightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel? = Self.makeModel()

    var body: some Scene {
        WindowGroup {
            if let app {
                RootView(app: app)
                    // A new day, or another time zone: the events are laid out again, and the reminders follow.
                    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                        .receive(on: DispatchQueue.main)) { _ in
                        Task { await app.dayChanged() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                        .receive(on: DispatchQueue.main)) { _ in
                        Task { await app.phoneZoneChanged() }
                    }
            } else {
                ContentUnavailableView(
                    "Outwright can't open its mail store", systemImage: "exclamationmark.triangle",
                    description: Text("Restart the app. If it happens again, reinstall it."))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The reminders are handed to the phone again on every return to the front (the sample too).
            if let app, phase == .active {
                Task { await app.sync.rescheduleReminders() }
            }
            guard let app, !Self.isSample else { return }
            switch phase {
            case .active:
                StoreGrace.sharing.cameToFront()
                // What the notification extension stored meanwhile shows in the lists.
                try? app.store.lookAgain()
                app.sceneChanged(toActive: true) { await WiFi.isOn() }
                Task { await AppPush.renewIfDue() }
            case .background:
                BackgroundRefresh.schedule()
                app.sceneChanged(toActive: false)
                app.sweepSetupFiles()
                StoreGrace.sharing.wentToBackground()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            // Turned off in settings: nothing is fetched and none is asked for again.
            guard BackgroundRefresh.isOn else { return }
            // The next one is asked for first, so a refresh cut short still leaves one coming.
            BackgroundRefresh.schedule()
            await StoreGrace.sharing.refresh {
                guard let app = Self.backgroundModel() else { return }
                // First, so the reminders are refilled even when the refresh is cut short.
                await app.sync.rescheduleReminders()
                await app.refresh()
                await app.announceNewMail()
                await AppPush.renewIfDue()
            }
        }
    }

    /// The test hooks this build names (only the end-to-end build has any).
    @MainActor static let hooks = LaunchHookSet(named: BuildSettings.main.launchHooks)

    /// The app runs on a sample (the end-to-end build's `--sample`).
    @MainActor static var isSample: Bool { hooks.startsSample }

    /// The sample when a hook gives one; otherwise the store in Application Support.
    @MainActor
    static func makeModel() -> AppModel? {
        if let sample = hooks.sampleModel() {
            return sample
        }
        guard let folder = applicationSupport() else { return nil }
        let url = storeURL(in: folder)
        // Application Support, where the modules' files stay (a fresh start clears the app group too).
        hooks.prepare(storeFolder: folder)
        guard let store = try? MailStore(path: url) else { return nil }
        hooks.storeOpened(store)
        removeLeftoverAttachmentFiles()
        SetupModel.removeLeftovers()
        // The modules keep their own files where they always were; only the store moved.
        var modules = Composition.modules(store: store, folder: folder, hooks: hooks.hooks)
        modules.providers = hooks.providers(modules.providers)
        let providers = ProviderSet([OwnServerProvider()] + modules.providers)
        DefaultSignature.fillEmpty(store: store)
        DefaultSignature.replaceOld(store: store)
        let offset = hooks.clockOffset
        let clock: @Sendable () -> Date = { [offset] in Date().addingTimeInterval(offset) }
        store.setOpenings(modules.openings)
        let journal = DiagnosticsJournal(
            fileURL: DiagnosticsJournal.place(container: PushPlaces.container, fallback: folder))
        // Off the main thread: a count over a large store, or the extension holding the file, must
        // not hold up the first screen.
        Task.detached(priority: .utility) { noteLaunch(journal, store: store, at: url) }
        let sync = SyncCoordinator(
            store: store, secrets: KeychainSecretStore(), tokens: providers.tokens, available: Set(providers.ids),
            now: clock, phoneContacts: SystemPhoneContacts(), reminders: SystemReminders(now: clock),
            graphBases: providers.graphBases, meetingWording: AppModel.meetingWording,
            protections: modules.protections, journal: journal)
        let model = AppModel(store: store, sync: sync)
        model.modules = modules
        model.now = clock
        model.push = AppPush.support()
        Task { await model.movePushToLocalWhereNotIncluded() }
        model.diagnostics = Metrics.start()
        NetworkWatch.start { [weak model] in model?.networkChanged() }
        StoreChanges.observe { [weak model] in try? model?.store.lookAgain() }
        model.showBadge()
        shared = model
        front = model
        openPendingEvent()
        return model
    }

    /// The model in front, the sample's too: where a tapped reminder opens its event.
    @MainActor static var front: AppModel?
    /// A reminder tapped before the model was made.
    @MainActor static var pendingEvent: EventRequest?

    static func open(_ request: EventRequest) {
        if let front {
            front.showEvent(request)
        } else {
            pendingEvent = request
        }
    }

    /// A new-mail notice tapped before the model was made.
    @MainActor static var pendingMessage: MessageRequest?

    static func open(_ request: MessageRequest) {
        if let front {
            front.showMessage(request)
        } else {
            pendingMessage = request
        }
    }

    @MainActor
    static func openPendingEvent() {
        if let request = pendingMessage, let front {
            pendingMessage = nil
            front.showMessage(request)
        }
        guard let request = pendingEvent, let front else { return }
        pendingEvent = nil
        front.showEvent(request)
    }

    /// The model a background refresh works on: the app's own, never the sample's.
    @MainActor static var shared: AppModel?

    @MainActor
    static func backgroundModel() -> AppModel? {
        shared
    }

    /// The launch, the store's size and any migrations opening it applied, for the diagnostics.
    private nonisolated static func noteLaunch(_ journal: DiagnosticsJournal, store: MailStore, at url: URL) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        journal.note(.launch(version: version, build: info["CFBundleVersion"] as? String ?? ""))
        let bytes = [url.path, url.path + "-wal"].reduce(Int64(0)) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
        journal.note(.store(bytes: bytes, messages: (try? store.messageCount()) ?? 0))
        if !store.migrated.names.isEmpty {
            journal.note(.migration(names: store.migrated.names, milliseconds: Int(store.migrated.seconds * 1_000)))
        }
    }

    static func applicationSupport() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// In the app group, where the notification extension reaches it, moved there once from
    /// Application Support; in Application Support for a build without an app group.
    static func storeURL(in applicationSupport: URL) -> URL {
        let old = applicationSupport.appendingPathComponent("mail.sqlite")
        guard let container = PushPlaces.container else { return old }
        return StoreFile.place(old: old, new: PushPlaces.store(in: container))
    }
}

/// Whether the phone is on Wi-Fi now (bodies are prefetched only then).
enum WiFi {
    static func isOn() async -> Bool {
        await withCheckedContinuation { continuation in
            let answered = Once()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard answered.first() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: DispatchQueue(label: "com.10boring.outwright.wifi"))
        }
    }
}

/// True the first time only.
final class Once: Sendable {
    private let done = Mutex(false)

    func first() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
