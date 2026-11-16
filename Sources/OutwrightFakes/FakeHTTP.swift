// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// HTTP/1.1 framing for the CardDAV fake: requests with `Content-Length` bodies only (the path
/// read without its query, into `FakeHTTPServer`'s request), answers with `Content-Length` always.
enum FakeHTTP {
    static func read(_ connection: FakeConnection) async -> FakeHTTPRequest? {
        guard let line = await connection.readLine(maxBytes: 8192) else {
            return nil
        }
        let parts = fakeText(line).split(separator: " ")
        guard parts.count == 3, let target = parts[1].split(separator: "?").first else {
            return nil
        }
        var headers: [String: String] = [:]
        while true {
            guard let raw = await connection.readLine(maxBytes: 65536) else {
                return nil
            }
            if raw.isEmpty {
                break
            }
            let text = fakeText(raw)
            if let colon = text.firstIndex(of: ":") {
                headers[text[..<colon].lowercased()] =
                    text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...(64 << 20)).contains(length) else {
            return nil
        }
        guard let body = length == 0 ? Data() : await connection.read(exactly: length) else {
            return nil
        }
        return FakeHTTPRequest(method: String(parts[0]), path: String(target), headers: headers, body: body)
    }

    static func response(_ status: Int, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        return Data(text.utf8) + body
    }

    static func xml(_ status: Int, _ text: String) -> Data {
        response(
            status, headers: [("Content-Type", "application/xml; charset=utf-8")],
            body: Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?>" + text).utf8))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static let reasons = [
        200: "OK", 201: "Created", 204: "No Content", 207: "Multi-Status", 301: "Moved Permanently",
        401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
        412: "Precondition Failed"
    ]

    private static func reason(_ status: Int) -> String {
        reasons[status] ?? "Status"
    }
}
