// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync
import Synchronization

/// A resolver with fixed SRV answers, which remembers every name it was asked.
final class FakeDoH: DoHResolving {
    // swiftlint:disable:next large_tuple
    typealias Record = (target: String, port: UInt16, priority: UInt16)

    private let answers: [String: [Record]]
    private let log = Mutex<[String]>([])

    init(_ answers: [String: [Record]] = [:]) {
        self.answers = answers
    }

    var asked: [String] {
        log.withLock { $0 }
    }

    func srv(_ name: String) async -> [Record] {
        log.withLock { $0.append(name) }
        return answers[name] ?? []
    }

    func mx(_ name: String) async -> [MXRecord] { [] }
}
