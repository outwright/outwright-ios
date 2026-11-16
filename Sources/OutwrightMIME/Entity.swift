// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// One entity of a message as it was written (RFC 2045): its type, its header fields, its bytes
/// and, for a multipart, its direct parts. For code that must judge a message by its structure.
public struct MIMEEntity: Sendable {
    /// The Content-Type's value, lower-cased; `text/plain` when there is none.
    public let type: String
    /// The Content-Type's parameters, by lower-case name.
    public let parameters: [String: String]
    public let headers: [(name: String, value: String)]
    /// The entity's own bytes: its header block and body as written.
    public let raw: Data
    /// The body with its transfer encoding undone.
    public let body: Data
    /// A multipart's direct parts, each read without parts of its own (read one's `raw` again for those).
    public let parts: [MIMEEntity]
}

extension MIMEParser {
    /// The message's root entity and its direct parts, within `limits`.
    public static func entity(_ data: Data, limits: MIMELimits = .default) throws(MIMEError) -> MIMEEntity {
        guard !data.isEmpty else { throw .notAMessage }
        guard data.count <= limits.messageBytes else { throw .tooLarge }
        let buf = [UInt8](data)
        let entity = try EntityReader.read(buf, range: 0..<buf.count, limits: limits, withParts: true)
        guard !entity.headers.isEmpty else { throw .notAMessage }
        return entity
    }
}

enum EntityReader {
    static func read(
        _ buf: [UInt8], range: Range<Int>, limits: MIMELimits, withParts: Bool
    ) throws(MIMEError) -> MIMEEntity {
        let range = range.clamped(to: buf.indices)
        let block = try HeaderBlock.parse(
            buf, start: range.lowerBound, end: range.upperBound, limit: limits.headerBytes)
        let headers = Headers(block.fields)
        let type = StructuredHeader.parse(headers["content-type"] ?? "")
        let mime = type.value.lowercased()
        let body = min(block.bodyStart, range.upperBound)..<range.upperBound
        var parts: [MIMEEntity] = []
        let boundary = type.params["boundary"] ?? ""
        if withParts, mime.hasPrefix("multipart/"), !boundary.isEmpty {
            var walker = PartWalker(buf: buf, limits: limits)
            for child in try walker.split(body, boundary: boundary) {
                parts.append(try read(buf, range: child, limits: limits, withParts: false))
            }
        }
        return MIMEEntity(
            type: mime.isEmpty ? "text/plain" : mime, parameters: type.params, headers: block.fields,
            raw: Data(buf[range]),
            body: Data(TransferEncoding.decode(Array(buf[body]), encoding: headers["content-transfer-encoding"])),
            parts: parts)
    }
}
