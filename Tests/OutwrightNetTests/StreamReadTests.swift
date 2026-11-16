// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import OutwrightNet
import Testing

@Suite struct StreamReadTests {
    /// The stream task can answer a read twice: once with its result and again with "cancelled"
    /// when the connection is closed (seen on iOS). The first answer counts; the second is ignored.
    @Test func aSecondAnswerIsIgnored() async throws {
        let result = try await StreamRead.once { answer in
            answer(Data("x".utf8), false, nil)
            answer(nil, false, URLError(.cancelled))
        }
        #expect(result.0 == Data("x".utf8))
        #expect(result.1 == false)
    }

    @Test func aFirstErrorIsThrownAndALaterAnswerIgnored() async {
        await #expect(throws: URLError.self) {
            _ = try await StreamRead.once { answer in
                answer(nil, false, URLError(.timedOut))
                answer(nil, false, URLError(.cancelled))
            }
        }
    }
}

@Suite struct StreamWriteTests {
    /// A write can be answered twice as a read can: the first answer counts.
    @Test func aSecondAnswerIsIgnored() async throws {
        try await StreamWrite.once { answer in
            answer(nil)
            answer(URLError(.cancelled))
        }
    }

    @Test func aFirstErrorIsThrown() async {
        await #expect(throws: URLError.self) {
            try await StreamWrite.once { answer in
                answer(URLError(.timedOut))
                answer(nil)
            }
        }
    }
}
