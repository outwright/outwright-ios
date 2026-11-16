// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import MetricKit
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
        return DiagnosticsSource(
            payloads: { archive.recent() },
            log: { DiagnosticsLog.recent(since: Date().addingTimeInterval(-24 * 60 * 60)) })
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
