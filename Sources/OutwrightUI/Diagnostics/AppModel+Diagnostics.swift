// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension AppModel {
    /// The diagnostics report, for a new message the owner reads and sends. The log, the payloads
    /// and the report are read off the main actor: reading the log can take a while.
    func diagnosticsReport() async -> Data {
        let source = diagnostics
        let version = SettingsView.version
        let accounts = accounts
        let problems = syncProblems
        return await Task.detached {
            let payloads = source.payloads()
            let report = DiagnosticsReport(
                version: version, system: ProcessInfo.processInfo.operatingSystemVersionString,
                accounts: accounts, problems: problems, payloads: payloads, log: source.log())
            DiagnosticsLog.reportBuilt(payloads: payloads.count)
            return Data(report.text.utf8)
        }.value
    }
}
