// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightModel
import OutwrightNet
public import OutwrightSetup
public import OutwrightStore

/// The subscribed calendars, each with its address (a secret: it often holds a token of its own).
public struct SubscriptionsSetupPart: SetupPart {
    public let name = "subscriptions"
    public let version = 1
    public let title: String

    let store: MailStore
    let secrets: any SecretStore

    public init(store: MailStore, secrets: any SecretStore, title: String = "Subscribed calendars") {
        self.title = title
        self.store = store
        self.secrets = secrets
    }

    /// The part's JSON, version 1.
    struct Content: Codable {
        var calendars: [CalendarEntry]
    }

    /// The longest calendar name kept.
    static let maxName = 1_024

    public func export() async throws(SetupError) -> Data {
        let held: [CalendarSubscription]
        do { held = try store.subscriptions() } catch { throw .unavailable }
        var entries: [CalendarEntry] = []
        for subscription in held {
            let address: Secret?
            do { address = try secrets.subscriptionAddress(subscription.key) } catch { throw .unavailable }
            // A subscription without an address is of no use anywhere else.
            guard let address else { continue }
            entries.append(
                CalendarEntry(
                    key: subscription.key, name: subscription.calendar.name, color: subscription.calendar.color,
                    address: address.reveal()))
        }
        return try SetupJSON.encode(Content(calendars: entries))
    }

    public func summary(of content: Data) throws(SetupError) -> [SetupItem] {
        try read(content).map { Self.item($0) }
    }

    /// Every subscribed calendar; one whose address is missing from the keychain is left out of the
    /// file, which only the keychain can tell.
    public func items() async -> [SetupItem] {
        ((try? store.subscriptions()) ?? []).map { SetupItem(kind: .calendar, label: $0.calendar.name) }
    }

    public func importContent(_ content: Data, version: Int) async -> SetupImportReport {
        guard version <= self.version else { return .notRead(title) }
        guard let entries = try? read(content), let held = try? store.subscriptions() else {
            return .unreadable(title)
        }
        var keys = Set(held.map(\.key))
        var addresses = Set(held.compactMap { (try? secrets.subscriptionAddress($0.key))?.reveal() })
        var report = SetupImportReport()
        for entry in entries {
            let item = Self.item(entry)
            guard entry.address.utf8.count <= SetupJSON.maxSecretLength, entry.name.utf8.count <= Self.maxName,
                let url = SubscriptionSyncer.address(entry.address), let host = url.host()
            else {
                report.skipped.append(SetupSkip(item: item, reason: .failed))
                continue
            }
            let address = url.absoluteString
            guard !addresses.contains(address) else {
                report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
                continue
            }
            if keys.contains(entry.key) {
                if fillAddress(address, of: entry.key, item: item, into: &report) { addresses.insert(address) }
                continue
            }
            do {
                try secrets.setSubscriptionAddress(Secret(address), for: entry.key)
            } catch {
                report.skipped.append(SetupSkip(item: item, reason: .failed))
                continue
            }
            do {
                _ = try store.addSubscription(key: entry.key, host: host, name: entry.name, color: entry.color)
            } catch {
                try? secrets.removeSubscriptionAddress(entry.key)
                report.skipped.append(SetupSkip(item: item, reason: .failed))
                continue
            }
            keys.insert(entry.key)
            addresses.insert(address)
            report.added.append(item)
        }
        return report
    }

    /// The calendar is here: without its address (the keychain stayed with the phone a backup came
    /// from) the address is filled in, and its name and colour stay as they are. True when filled in.
    private func fillAddress(
        _ address: String, of key: UUID, item: SetupItem, into report: inout SetupImportReport
    ) -> Bool {
        // It has one, or whether it has one is not known: it is left as it is.
        guard hasAddress(key) == false else {
            report.skipped.append(SetupSkip(item: item, reason: .alreadyHere))
            return false
        }
        do {
            try secrets.setSubscriptionAddress(Secret(address), for: key)
        } catch {
            report.skipped.append(SetupSkip(item: item, reason: .failed))
            return false
        }
        report.restored.append(item)
        return true
    }

    /// Whether the keychain holds the subscription's address; nil when it could not say.
    private func hasAddress(_ key: UUID) -> Bool? {
        do { return try secrets.subscriptionAddress(key) != nil } catch { return nil }
    }

    private func read(_ content: Data) throws(SetupError) -> [CalendarEntry] {
        let entries = try SetupJSON.decode(Content.self, from: content).calendars
        guard entries.count <= SetupJSON.maxItems else { throw .tooLarge }
        return entries
    }

    private static func item(_ entry: CalendarEntry) -> SetupItem {
        SetupItem(kind: .calendar, label: entry.name)
    }
}

/// One subscribed calendar in the subscriptions part.
struct CalendarEntry: Codable {
    /// The keychain key of the address, kept.
    var key: UUID
    var name: String
    /// 0xRRGGBB.
    var color: Int
    var address: String
}
