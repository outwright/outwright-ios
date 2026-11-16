// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// swiftlint:disable:next large_tuple
public typealias SRVRecord = (target: String, port: UInt16, priority: UInt16)
/// A mail exchanger: its host, lower-case without the final dot, and its preference (lower first).
public typealias MXRecord = (host: String, preference: UInt16)

/// Looks up SRV and MX records. Only the name asked about is sent.
public protocol DoHResolving: Sendable {
    func srv(_ name: String) async -> [SRVRecord]
    /// The domain's mail exchangers (RFC 5321); empty for none, a null MX (RFC 7505) or any
    /// failure.
    func mx(_ name: String) async -> [MXRecord]
}

/// Cloudflare's DNS over HTTPS, JSON API. The request carries the name and the record type,
/// no cookies and nothing cached; any failure is an empty answer.
public struct CloudflareDoH: DoHResolving {
    static let endpoint = "https://cloudflare-dns.com/dns-query"
    static let maxBytes = 64 << 10
    static let maxRecords = 32

    let endpoint: String
    let timeout: TimeInterval

    public init() {
        self.init(endpoint: Self.endpoint)
    }

    init(endpoint: String, timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func srv(_ name: String) async -> [SRVRecord] {
        await answer(name, type: "SRV").map(Self.records(from:)) ?? []
    }

    public func mx(_ name: String) async -> [MXRecord] {
        await answer(name, type: "MX").map(Self.exchanges(from:)) ?? []
    }

    /// The JSON answer for `name` and `type`; nil on any failure.
    private func answer(_ name: String, type: String) async -> Data? {
        guard var request = Self.request(for: name, type: type, endpoint: endpoint) else {
            return nil
        }
        request.timeoutInterval = timeout
        let configuration = Self.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxBytes
        else {
            return nil
        }
        return data
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        // Nothing about this device or its owner: a generic agent and no language.
        configuration.httpAdditionalHeaders = ["User-Agent": "Outwright"]
        return configuration
    }

    static func request(for name: String, type: String = "SRV", endpoint: String = endpoint) -> URLRequest? {
        guard Discovery.isHostName(name, allowUnderscore: true), var parts = URLComponents(string: endpoint) else {
            return nil
        }
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type)]
        guard let url = parts.url else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        // URLSession adds the device's languages unless told otherwise; an empty value sends none.
        request.setValue("", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        return request
    }

    /// The SRV records of an answer: `priority weight port target` (RFC 2782), bounded.
    static func records(from json: Data) -> [SRVRecord] {
        guard json.count <= maxBytes, let reply = try? JSONDecoder().decode(DNSReply.self, from: json),
              reply.status == 0
        else {
            return []
        }
        var out: [SRVRecord] = []
        for answer in (reply.answer ?? []).prefix(maxRecords) where answer.type == 33 {
            let fields = (answer.data ?? "").prefix(512).split(separator: " ")
            guard fields.count == 4, let priority = UInt16(fields[0]), UInt16(fields[1]) != nil,
                  let port = UInt16(fields[2])
            else {
                continue
            }
            out.append((target: String(fields[3]), port: port, priority: priority))
        }
        return out
    }
}

extension CloudflareDoH {
    /// The mail exchangers of an answer: `preference exchange` (RFC 1035), bounded; a null MX's
    /// `.` is none.
    static func exchanges(from json: Data) -> [MXRecord] {
        guard json.count <= maxBytes, let reply = try? JSONDecoder().decode(DNSReply.self, from: json),
              reply.status == 0
        else {
            return []
        }
        var out: [MXRecord] = []
        for answer in (reply.answer ?? []).prefix(maxRecords) where answer.type == 15 {
            let fields = (answer.data ?? "").prefix(512).split(separator: " ")
            guard fields.count == 2, let preference = fields.first.flatMap({ UInt16($0) }), let host = fields.last
            else {
                continue
            }
            let name = (host.hasSuffix(".") ? host.dropLast() : host[...]).lowercased()
            if !name.isEmpty { out.append((host: name, preference: preference)) }
        }
        return out
    }
}

/// Cloudflare's JSON answer, the parts read.
private struct DNSReply: Decodable {
    var status: Int?
    var answer: [DNSAnswer]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answer = "Answer"
    }
}

private struct DNSAnswer: Decodable {
    var type: Int?
    var data: String?
}
