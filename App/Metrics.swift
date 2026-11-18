// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import MetricKit
import OutwrightSync
import OutwrightUI

/// MetricKit's daily metrics and its crash and hang diagnostics, kept on the phone for the owner's
/// diagnostics report. Nothing is sent anywhere.
final class Metrics: NSObject, MXMetricManagerSubscriber, Sendable {
    let archive: DiagnosticsArchive

    /// The one subscriber, held here: MetricKit doesn't keep it.
    @MainActor private static var shared: Metrics?

    init(archive: DiagnosticsArchive) {
        self.archive = archive
    }

    /// The archive in Application Support; nil when that folder can't be found.
    static func archiveFolder() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Subscribes to MetricKit and answers where a report reads its payloads and log lines.
    @MainActor
    static func start() -> DiagnosticsSource {
        guard let folder = archiveFolder() else { return .empty }
        let metrics = Metrics(archive: DiagnosticsArchive(folder: folder))
        MXMetricManager.shared.add(metrics)
        shared = metrics
        let archive = metrics.archive
        let journal = DiagnosticsJournal(
            fileURL: DiagnosticsJournal.place(
                container: PushPlaces.container, fallback: folder.deletingLastPathComponent()))
        return DiagnosticsSource(
            payloads: { archive.recent() },
            // The push notes from before the journal, until they are no longer there.
            log: {
                let since = Date().addingTimeInterval(-DiagnosticsJournal.kept)
                guard let container = PushPlaces.container else { return [] }
                return PushNoticeLog(fileURL: PushPlaces.notices(in: container)).lines(since: since)
            },
            journal: { journal.entries() },
            pushFingerprints: {
                guard let container = PushPlaces.container else { return [:] }
                let registry = PushRegistry(fileURL: PushPlaces.registry(in: container), vault: KeychainPushVault())
                return Dictionary(
                    registry.registrations().map { ($0.account.id, PushNoticeLog.fingerprint($0.relay.id)) },
                    uniquingKeysWith: { first, _ in first })
            })
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            archive.keep(payload.jsonRepresentation(), at: Date())
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            archive.keep(payload.jsonRepresentation(), at: Date())
        }
    }
}
