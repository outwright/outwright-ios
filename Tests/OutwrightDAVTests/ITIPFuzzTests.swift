// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

@Suite struct ITIPFuzzTests {
    typealias F = ITIPFixtures
    static let seeds: [Data] = [
        F.outlook(), F.outlook(method: "CANCEL", sequence: 3), F.google(), F.google(method: "ADD"), F.stalwart(),
        F.reply(), F.googleCancel(recurrenceID: "20261117T080000Z"),
    ]
    static let methods = ["", "REQUEST", "ADD", "CANCEL", "REPLY", "PUBLISH", "request"]

    static func mutate(_ seed: Data, _ rng: inout SeededGenerator) -> Data {
        var bytes = Array(seed)
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            for _ in 0..<Int.random(in: 1...16, using: &rng) where !bytes.isEmpty {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
        case 1:
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
        case 2:
            // A line dropped or doubled.
            var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            if !lines.isEmpty {
                let index = Int.random(in: 0..<lines.count, using: &rng)
                if Bool.random(using: &rng) { lines.remove(at: index) } else { lines.insert(lines[index], at: index) }
            }
            bytes = Array(lines.joined(separator: "\r\n").utf8)
        default:
            // Random bytes spliced in.
            let at = Int.random(in: 0...bytes.count, using: &rng)
            bytes.insert(contentsOf: (0..<Int.random(in: 1...40, using: &rng)).map { _ in
                UInt8.random(in: 0...255, using: &rng)
            }, at: at)
        }
        return Data(bytes)
    }

    @Test func readNeverTrapsOverArbitraryBytes() {
        var rng = SeededGenerator(state: 5_546)
        for round in 0..<10_000 {
            let method = Self.methods[round % Self.methods.count]
            let data: Data
            if round % 2 == 0 {
                data = Data((0..<Int.random(in: 0...2_048, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            } else {
                data = Self.mutate(Self.seeds[round % Self.seeds.count], &rng)
            }
            guard let message = ITIP.read(data, method: method) else { continue }
            #expect(!message.uid.isEmpty)
            #expect(message.sequence >= 0)
            _ = ITIP.senderMayApply(message, from: "org@example.org")
        }
    }

    @Test func applyingThenSettingPartstatNeverTraps() {
        var rng = SeededGenerator(state: 6_638)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let answers = ["ACCEPTED", "TENTATIVE", "DECLINED", "", "x\r\ny"]
        var applied = 0
        for round in 0..<2_000 {
            let incoming = Self.mutate(Self.seeds[round % Self.seeds.count], &rng)
            let stored = Self.mutate(Self.seeds[Int.random(in: 0..<Self.seeds.count, using: &rng)], &rng)
            guard let message = ITIP.read(incoming, method: "REQUEST") else { continue }
            // The stored copy: as the app writes one, or any calendar that reads.
            let base = round % 2 == 0
                ? ITIP.read(stored, method: "REQUEST").map { ITIP.applying($0, to: nil, ownEmail: F.me) }
                : try? ICalendarReader.calendar(stored)
            let result = ITIP.applying(message, to: base, ownEmail: F.me)
            #expect(result.first("METHOD") == nil)
            _ = ITIP.isNewer(message, than: result)
            let recurrence = Bool.random(using: &rng)
                ? ICalProperty(name: "RECURRENCE-ID", value: Bool.random(using: &rng) ? "20261117T080000Z" : "junk")
                : nil
            let answer = answers[round % answers.count]
            let answered = ITIP.settingPartstat(answer, in: result, ownEmail: F.me, recurrenceID: recurrence)
            _ = ITIP.settingScheduleAgentClient(answered)
            if let reply = ITIP.reply(from: answered, ownEmail: F.me, partstat: answer, recurrenceID: recurrence,
                                      now: now) {
                // One VEVENT for an occurrence; for the series, one more per override (#52).
                let overrides = ITIP.events(answered).filter { $0.first("RECURRENCE-ID") != nil }.count
                let count = ITIP.events(reply).count
                #expect(recurrence == nil ? (1...1 + overrides).contains(count) : count == 1)
                #expect(ITIP.events(reply).allSatisfy { $0.all("ATTENDEE").count == 1 })
                _ = ICalendarWriter.write(reply)
            }
            _ = ICalendarWriter.write(answered)
            applied += 1
        }
        #expect(applied > 100)
    }
}
