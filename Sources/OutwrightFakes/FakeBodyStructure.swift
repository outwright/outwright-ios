// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// BODYSTRUCTURE (RFC 9051 §7.5.2) of a stored message, for the fake IMAP server: its MIME parts by
/// type, parameters, encoding and size. An attached message (`message/rfc822`) is given as a
/// basic part, without its envelope and own structure; enough for what the app reads.
enum FakeBodyStructure {
    static func of(_ message: Data) -> String {
        part(message, depth: 0)
    }

    private static func part(_ data: Data, depth: Int) -> String {
        let (head, body) = FakeIMAPServer.split(data)
        let fields = headerFields(head)
        let kind = contentType(fields["content-type"] ?? "text/plain")
        let (type, subtype, parameters) = (kind.type, kind.subtype, kind.parameters)
        let encoding = fields["content-transfer-encoding"]?.trimmingCharacters(in: .whitespaces) ?? "7BIT"
        if type == "multipart", depth < 8, let boundary = parameters.first(where: { $0.0 == "boundary" })?.1 {
            let children = parts(body, boundary: boundary).map { part($0, depth: depth + 1) }.joined()
            return "(\(children.isEmpty ? part(Data(), depth: depth + 1) : children) \(quoted(subtype.uppercased())))"
        }
        let list = parameters.isEmpty ? "NIL" : "(" + parameters.map { "\(quoted($0.0)) \(quoted($0.1))" }
            .joined(separator: " ") + ")"
        var fieldsOut = "\(quoted(type.uppercased())) \(quoted(subtype.uppercased())) \(list) NIL NIL "
            + "\(quoted(encoding.uppercased())) \(body.count)"
        if type == "text" {
            fieldsOut += " \(body.filter { $0 == 10 }.count)"
        }
        return "(\(fieldsOut))"
    }

    private static func headerFields(_ head: Data) -> [String: String] {
        let text = (String(bytes: head, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [String: String] = [:]
        var name: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == " " || line.first == "\t", let current = name {
                fields[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let key = halves[0].lowercased()
            name = key
            fields[key] = halves[1].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    private struct ContentType {
        var type: String
        var subtype: String
        var parameters: [(String, String)]
    }

    private static func contentType(_ value: String) -> ContentType {
        let pieces = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let kind = (pieces.first ?? "text/plain").lowercased().split(separator: "/")
        var parameters: [(String, String)] = []
        for piece in pieces.dropFirst() {
            let halves = piece.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let value = halves[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            parameters.append((halves[0].lowercased(), value))
        }
        return ContentType(
            type: kind.first.map(String.init) ?? "text", subtype: kind.count > 1 ? String(kind[1]) : "plain",
            parameters: parameters)
    }

    /// The parts between `--boundary` lines, each without the line break before the next delimiter.
    private static func parts(_ body: Data, boundary: String) -> [Data] {
        let text = (String(bytes: body, encoding: .utf8) ?? "")
        let delimiter = "--" + boundary
        var found: [Data] = []
        for (index, chunk) in text.components(separatedBy: delimiter).enumerated() where index > 0 {
            guard !chunk.hasPrefix("--") else { break }
            var part = chunk
            // "\r\n" is one Character, as "\n" is.
            if part.hasPrefix("\r\n") || part.hasPrefix("\n") { part.removeFirst() }
            if part.hasSuffix("\r\n") || part.hasSuffix("\n") { part.removeLast() }
            found.append(Data(part.utf8))
        }
        return found
    }

    private static func quoted(_ text: String) -> String {
        FakeIMAPServer.quoted(text)
    }
}
