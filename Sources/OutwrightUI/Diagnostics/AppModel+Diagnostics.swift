// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension AppModel {
    /// The diagnostics report, for the support form the owner reviews and sends. The log, the payloads
    /// and the report are read off the main actor: reading the log can take a while.
    func diagnosticsReport() async -> Data {
        let source = diagnostics
        let version = SettingsView.version
        let accounts = accounts
        let problems = syncProblems
        let system = Self.systemDescription
        return await Task.detached {
            let payloads = source.payloads()
            let report = DiagnosticsReport(
                version: version, system: system,
                accounts: accounts, problems: problems, payloads: payloads, log: source.log(),
                journal: source.journal(), pushFingerprints: source.pushFingerprints())
            DiagnosticsLog.reportBuilt(payloads: payloads.count)
            return Data(report.text.utf8)
        }.value
    }

    /// The kind of device (iPhone or iPad) and its system version: an iPad's layout is not a phone's.
    static var systemDescription: String {
        #if canImport(UIKit)
            "\(UIDevice.current.model), \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
            ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
