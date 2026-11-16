// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OSLog
import OutwrightModel

/// Where a diagnostics report reads what the phone kept: MetricKit payloads and recent log lines.
/// The app shell fills it in; tests and the sample give their own.
public struct DiagnosticsSource: Sendable {
    public var payloads: @Sendable () -> [Data]
    public var log: @Sendable () -> [String]

    public init(payloads: @escaping @Sendable () -> [Data], log: @escaping @Sendable () -> [String]) {
        self.payloads = payloads
        self.log = log
    }

    public static let empty = DiagnosticsSource(payloads: { [] }, log: { [] })
}

/// This process's own log lines, from the unified log.
public enum DiagnosticsLog {
    private static let logger = Logger(subsystem: logSubsystem, category: "ui")

    /// The app's newest log lines since `date` (as many as a report holds), oldest first; empty
    /// when the log can't be read. Values logged as private stay redacted here.
    public static func recent(since date: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
            let entries = try? store.getEntries(
                at: store.position(date: date),
                matching: NSPredicate(format: "subsystem == %@", logSubsystem))
        else { return [] }
        let keep = DiagnosticsReport.logLines
        var lines: [String] = []
        for entry in entries {
            lines.append("\(entry.date.ISO8601Format()) \(entry.composedMessage)")
            if lines.count >= keep * 2 { lines.removeFirst(keep) }
        }
        return Array(lines.suffix(keep))
    }

    /// Notes in the log that a report was built, with how many payloads it holds and nothing else.
    static func reportBuilt(payloads: Int) {
        logger.info("Diagnostics report built with \(payloads, privacy: .public) payloads")
    }
}
