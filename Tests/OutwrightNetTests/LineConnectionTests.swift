// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightNet
import Testing

@Suite struct LineConnectionTests {
    /// An echo server that answers each line with "> line".
    private func echo() async throws -> (FakeListener, UInt16) {
        let listener = FakeListener { connection in
            while let line = await connection.readLine() {
                connection.send(Data("> ".utf8) + line + Data("\r\n".utf8))
            }
        }
        return (listener, try await listener.start())
    }

    @Test func readsLinesAndExactBytes() async throws {
        let (listener, port) = try await echo()
        defer { listener.stop() }
        let conn = try await LineConnection.open(.init(host: "127.0.0.1", port: port, security: .plainLoopbackOnly))
        try await conn.write(Data("hello\r\nworld\r\n".utf8))
        #expect(try await conn.readLine() == Data("> hello".utf8))
        #expect(try await conn.read(exactly: 3) == Data("> w".utf8))
        #expect(try await conn.readLine() == Data("orld".utf8))
        await conn.close()
    }

    @Test func refusesOverlongLine() async throws {
        let (listener, port) = try await echo()
        defer { listener.stop() }
        let conn = try await LineConnection.open(.init(host: "localhost", port: port, security: .plainLoopbackOnly))
        try await conn.write(Data(String(repeating: "x", count: 5000).utf8) + Data("\r\n".utf8))
        await #expect(throws: NetError.lineTooLong) {
            _ = try await conn.readLine(maxBytes: 1000)
        }
        await conn.close()
    }

    @Test func reportsClosedConnection() async throws {
        let listener = FakeListener { connection in connection.close() }
        defer { listener.stop() }
        let port = try await listener.start()
        let conn = try await LineConnection.open(.init(host: "127.0.0.1", port: port, security: .plainLoopbackOnly))
        await #expect(throws: NetError.closed) {
            _ = try await conn.readLine()
        }
        await conn.close()
    }

    @Test func largeWriteIsSentInPiecesEachWithItsOwnTimeout() async throws {
        let total = 8 << 20
        let listener = FakeListener { connection in
            var received = 0
            while received < total {
                guard let piece = await connection.read(exactly: min(512 << 10, total - received)) else { return }
                received += piece.count
                try? await Task.sleep(for: .milliseconds(100))
            }
            connection.send(Data("ok\r\n".utf8))
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let conn = try await LineConnection.open(
            .init(host: "127.0.0.1", port: port, security: .plainLoopbackOnly), timeout: .milliseconds(700)
        )
        try await conn.write(Data(repeating: 0x61, count: total))
        // The socket's buffers can hold megabytes the server has yet to read at its slow pace: the
        // answer comes after them, so it gets a wait of its own, not the 700 ms of a written piece.
        #expect(try await conn.readLine(timeout: .seconds(30)) == Data("ok".utf8))
        await conn.close()
    }

    @Test func deadlineEndsADrippingLine() async throws {
        let listener = FakeListener { connection in
            for _ in 0..<100 {
                connection.send(Data("x".utf8))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let conn = try await LineConnection.open(.init(host: "127.0.0.1", port: port, security: .plainLoopbackOnly))
        let start = SuspendingClock.now
        await #expect(throws: NetError.timeout) {
            _ = try await conn.readLine(deadline: .now + .seconds(1))
        }
        #expect(SuspendingClock.now - start < .seconds(3))
        await conn.close()
    }

    /// Two reads at once (a caller that broke its own turn-taking) each get a whole line and
    /// never trap: the one that resumes second finds the buffer already consumed past it.
    @Test func twoReadsAtOnceEachGetAWholeLine() async throws {
        let listener = FakeListener { connection in
            connection.send(Data("abc".utf8))
            try? await Task.sleep(for: .milliseconds(300))
            connection.send(Data("def\r\nghi\r\n".utf8))
            try? await Task.sleep(for: .milliseconds(300))
            connection.send(Data("jkl\r\n".utf8))
            try? await Task.sleep(for: .seconds(2))
        }
        defer { listener.stop() }
        let port = try await listener.start()
        let conn = try await LineConnection.open(.init(host: "127.0.0.1", port: port, security: .plainLoopbackOnly))
        try await Task.sleep(for: .milliseconds(100))
        async let first = conn.readLine()
        async let second = conn.readLine()
        let lines = try await [first, second].map { String(decoding: $0, as: UTF8.self) }
        #expect(Set(lines).count == 2)
        #expect(Set(lines).isSubset(of: ["abcdef", "ghi", "jkl"]))
        await conn.close()
    }
}
