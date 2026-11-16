// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// One request a `FakeHTTPServer` received.
public struct FakeHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
}

/// What a route answers.
public struct FakeHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// Closes the connection without answering, as when an answer is lost on the way.
    public static let dropped = FakeHTTPResponse(status: 0)

    public static func json(_ status: Int, _ text: String) -> FakeHTTPResponse {
        FakeHTTPResponse(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }
}

/// An in-process HTTP/1.1 server on 127.0.0.1 for tests: one request per connection, header
/// names lower-cased, bodies up to 1 MiB.
public final class FakeHTTPServer: Sendable {
    private let listener: FakeListener

    public init(
        host: String = "127.0.0.1", port: UInt16 = 0,
        route: @escaping @Sendable (FakeHTTPRequest) async -> FakeHTTPResponse
    ) {
        listener = FakeListener(host: host, port: port) { connection in
            guard let request = await Self.read(connection) else {
                connection.close()
                return
            }
            let response = await route(request)
            guard response.status != 0 else {
                connection.close()
                return
            }
            var head = "HTTP/1.1 \(response.status) Fake\r\n"
            head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n"
            for (name, value) in response.headers {
                head += "\(name): \(value)\r\n"
            }
            connection.send(Data((head + "\r\n").utf8) + response.body)
            connection.close()
        }
    }

    public func start() async throws -> UInt16 {
        try await listener.start()
    }

    public func stop() {
        listener.stop()
    }

    private static func read(_ connection: FakeConnection) async -> FakeHTTPRequest? {
        guard let line = await connection.readLine(maxBytes: 8192) else {
            return nil
        }
        let parts = fakeText(line).split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        var headers: [String: String] = [:]
        while let raw = await connection.readLine(maxBytes: 8192) {
            if raw.isEmpty {
                break
            }
            let text = fakeText(raw)
            if let colon = text.firstIndex(of: ":") {
                let name = text[..<colon].lowercased()
                headers[name] = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data()
        if let length = headers["content-length"].flatMap({ Int($0) }), length > 0 {
            guard length <= 1 << 20, let data = await connection.read(exactly: length) else {
                return nil
            }
            body = data
        }
        return FakeHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }
}
