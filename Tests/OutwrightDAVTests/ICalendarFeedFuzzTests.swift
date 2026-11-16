// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import Testing

@testable import OutwrightDAV

@Suite struct ICalendarFeedFuzzTests {
    func check(_ data: Data) {
        guard let split = try? ICalendarFeed.split(data) else { return }
        #expect(split.objects.count <= DAVLimits.feedObjects)
        for item in split.objects {
            #expect((try? ICalendarReader.calendar(item.data)) != nil)
        }
    }

    @Test func arbitraryBytes() {
        var rng = SeededGenerator(state: 11)
        for _ in 0..<1_000 {
            check(rng.bytes(Int.random(in: 0...4096, using: &rng)))
        }
        let fixture = Array(SyntheticFeed.work)
        for _ in 0..<400 {
            var bytes = fixture
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
            default:
                for _ in 0..<Int.random(in: 1...8, using: &rng) where !bytes.isEmpty {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            check(Data(bytes))
        }
    }
}
