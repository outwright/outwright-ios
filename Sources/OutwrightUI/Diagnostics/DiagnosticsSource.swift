// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightSync
import OSLog
public import OutwrightModel

/// Where a diagnostics report reads what the phone kept: MetricKit payloads and recent log lines.
/// The app shell fills it in; tests and the sample give their own.
public struct DiagnosticsSource: Sendable {
    public var payloads: @Sendable () -> [Data]
    public var log: @Sendable () -> [String]
    /// The diagnostics journal, oldest first.
    public var journal: @Sendable () -> [JournalEntry]
    /// Each account's push subscription fingerprint, where push is on.
    public var pushFingerprints: @Sendable () -> [AccountID: String]

    public init(
        payloads: @escaping @Sendable () -> [Data], log: @escaping @Sendable () -> [String],
        journal: @escaping @Sendable () -> [JournalEntry] = { [] },
        pushFingerprints: @escaping @Sendable () -> [AccountID: String] = { [:] }
    ) {
        self.payloads = payloads
        self.log = log
        self.journal = journal
        self.pushFingerprints = pushFingerprints
    }

    public static let empty = DiagnosticsSource(payloads: { [] }, log: { [] })
}

/// What the diagnostics note in the unified log (for development; reports read the journal).
public enum DiagnosticsLog {
    private static let logger = Logger(subsystem: logSubsystem, category: "ui")

    /// Notes in the log that a report was built, with how many payloads it holds and nothing else.
    static func reportBuilt(payloads: Int) {
        logger.info("Diagnostics report built with \(payloads, privacy: .public) payloads")
    }
}
