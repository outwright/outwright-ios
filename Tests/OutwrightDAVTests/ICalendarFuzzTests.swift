// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import OutwrightDAV

@Suite struct ICalendarFuzzTests {
    func count(_ component: ICalComponent, depth: Int = 1) -> (components: Int, depth: Int, properties: Int) {
        var total = 1
        var deepest = depth
        var properties = component.properties.count
        for child in component.components {
            let inner = count(child, depth: depth + 1)
            total += inner.components
            deepest = max(deepest, inner.depth)
            properties = max(properties, inner.properties)
        }
        return (total, deepest, properties)
    }

    func check(_ data: Data) {
        do {
            let calendar = try ICalendarReader.calendar(data)
            let stats = count(calendar)
            #expect(stats.components <= DAVLimits.componentsPerResource)
            #expect(stats.depth <= DAVLimits.componentDepth)
            #expect(stats.properties <= DAVLimits.componentProperties)
            _ = ICalendarWriter.write(calendar)
        } catch {}
    }

    func ics(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n").utf8) }

    @Test func readerNeverTrapsOverArbitraryBytes() {
        var rng = SeededGenerator(state: 7)
        // Random bytes stop at the first line, so a few thousand cover what they can reach.
        for _ in 0..<2_000 {
            let size = Int.random(in: 0...8192, using: &rng)
            check(rng.bytes(size))
        }
        let fixtures: [Data] = [
            ics([
                "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VTIMEZONE", "TZID:Europe/Stockholm", "BEGIN:STANDARD",
                "DTSTART:19701025T030000", "END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT", "UID:a@example.org",
                "DTSTART;TZID=Europe/Stockholm:20261109T090000", "SUMMARY:Möte\\, med Bo",
                "ATTENDEE;CN=\"Lind: Bo\":mailto:bo@example.org", "BEGIN:VALARM", "TRIGGER:-PT15M", "END:VALARM",
                "END:VEVENT", "END:VCALENDAR",
            ]),
            ics(
                ["BEGIN:VCALENDAR", "BEGIN:VEVENT"] + (0..<3_000).map { "ATTENDEE:mailto:p\($0)@example.org" }
                    + ["END:VEVENT", "END:VCALENDAR"]),
            ics(Array(repeating: "BEGIN:VEVENT", count: 10_000)),
            ics(["BEGIN:VCALENDAR"] + Array(repeating: "BEGIN:VEVENT", count: 10_000)),
        ]
        for fixture in fixtures {
            check(fixture)
            // The large fixtures are there for the caps; the small one gets the most mutations.
            for _ in 0..<(fixture.count > 10_000 ? 40 : 200) {
                var bytes = Array(fixture)
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

    func randomText(_ rng: inout SeededGenerator) -> String {
        let alphabet = Array("abcXYZ019 ,;:\\\"^=-_åö€😀\n\r\t.")
        return String((0..<Int.random(in: 0...120, using: &rng)).compactMap { _ in alphabet.randomElement(using: &rng) })
    }

    func randomComponent(_ rng: inout SeededGenerator, depth: Int) -> ICalComponent {
        let names = ["VEVENT", "VTODO", "VALARM", "STANDARD", "X-THING"]
        let propertyNames = ["SUMMARY", "DTSTART", "ATTENDEE", "X-A-B", "CATEGORIES"]
        var component = ICalComponent(name: depth == 1 ? "VCALENDAR" : names.randomElement(using: &rng) ?? "VEVENT")
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            var parameters: [ContentParameter] = []
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                let values = (0..<Int.random(in: 1...2, using: &rng)).map { _ in randomText(&rng) }
                parameters.append(ContentParameter(name: ["CN", "TZID", "X-P"].randomElement(using: &rng) ?? "CN", values: values))
            }
            component.properties.append(
                ICalProperty(
                    name: propertyNames.randomElement(using: &rng) ?? "SUMMARY", parameters: parameters,
                    value: randomText(&rng)))
        }
        if depth < 4 {
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                component.components.append(randomComponent(&rng, depth: depth + 1))
            }
        }
        return component
    }

    /// What the writer is expected to change: line breaks in values and parameters become LF.
    func normalized(_ component: ICalComponent) -> ICalComponent {
        var result = component
        result.properties = component.properties.map { property in
            var copy = property
            copy.value = String(property.value.unicodeScalars.filter { $0 != "\r" && $0 != "\0" })
                .replacingOccurrences(of: "\n", with: "\\n")
            copy.parameters = property.parameters.map {
                ContentParameter(name: $0.name, values: $0.values.map { ContentLine.clean($0) })
            }
            return copy
        }
        result.components = component.components.map(normalized)
        return result
    }

    @Test func writeThenReadIsStable() throws {
        var rng = SeededGenerator(state: 99)
        for _ in 0..<500 {
            let tree = randomComponent(&rng, depth: 1)
            let data = ICalendarWriter.write(tree)
            let back = try ICalendarReader.calendar(data)
            #expect(back == normalized(tree))
            #expect(ICalendarWriter.write(back) == data)
        }
    }
}
