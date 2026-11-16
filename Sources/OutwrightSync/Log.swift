// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OSLog
import OutwrightModel

/// The sync module's log; dynamic values are private unless marked otherwise.
let syncLog = Logger(subsystem: logSubsystem, category: "sync")

/// The name of an error's case, without what it carries (which may hold server text): safe to log
/// in public.
func caseName(_ error: some Error) -> String {
    Mirror(reflecting: error).children.first?.label ?? String(describing: error)
}
