// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

enum DAVNamespace {
    static let dav = "DAV:"
    static let cardDAV = "urn:ietf:params:xml:ns:carddav"
    static let calendarServer = "http://calendarserver.org/ns/"
}

/// An element name with its namespace.
struct QName: Hashable, Sendable {
    let namespace: String
    let name: String

    static func dav(_ name: String) -> QName {
        QName(namespace: DAVNamespace.dav, name: name)
    }

    static func cardDAV(_ name: String) -> QName {
        QName(namespace: DAVNamespace.cardDAV, name: name)
    }

    static func calDAV(_ name: String) -> QName {
        QName(namespace: DAVNamespace.calDAV, name: name)
    }
}

/// A WebDAV multistatus (RFC 4918 §13), read with caps on size, depth and responses.
struct Multistatus: Sendable {
    /// One property: its text, the names of every element inside it, and the hrefs inside it.
    struct Property: Sendable {
        let name: QName
        /// The text with surrounding white space trimmed, for scalar values (ETag, names, tokens).
        var text = ""
        /// The text exactly as sent, for content such as `address-data`.
        var raw = ""
        var descendants: Set<QName> = []
        var hrefs: [String] = []
        /// The `name` attribute of every element inside it (`<comp name="VEVENT"/>`).
        var nameAttributes: [String] = []
    }

    struct Propstat: Sendable {
        var status = 0
        var properties: [Property] = []
    }

    struct Response: Sendable {
        var href = ""
        /// The response's own status, when it has one instead of propstats.
        var status: Int?
        var propstats: [Propstat] = []

        /// The property as the server gave it with a 2xx status, or nil.
        func property(_ name: QName) -> Property? {
            for propstat in propstats where (200..<300).contains(propstat.status) {
                if let found = propstat.properties.first(where: { $0.name == name }) {
                    return found
                }
            }
            return nil
        }
    }

    var responses: [Response] = []
    var syncToken: String?

    static func parse(_ data: Data) throws(DAVError) -> Multistatus {
        guard data.count <= DAVLimits.responseBytes else {
            throw .tooLarge
        }
        // No DTD: entities are a way to blow a small answer up.
        let doctype = "<!DOCTYPE"
        for marker in [Data(doctype.utf8), Data(doctype.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            Data(doctype.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })]
        where data.range(of: marker) != nil {
            throw .malformed
        }
        let reader = MultistatusReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let failure = reader.failure {
            throw failure
        }
        guard parsed, reader.sawRoot else {
            throw .malformed
        }
        return reader.result
    }

    /// The code in a status line such as `HTTP/1.1 404 Not Found`.
    static func statusCode(_ line: String) -> Int? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]), (100...999).contains(code) else {
            return nil
        }
        return code
    }
}

/// The parser's delegate: a stack of element names and the response being built.
final class MultistatusReader: NSObject, XMLParserDelegate {
    private(set) var result = Multistatus()
    private(set) var failure: DAVError?
    private(set) var sawRoot = false
    private var stack: [QName] = []
    private var response: Multistatus.Response?
    private var propstat: Multistatus.Propstat?
    private var property: Multistatus.Property?
    private var text = ""

    private func fail(_ error: DAVError, _ parser: XMLParser) {
        failure = failure ?? error
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let name = QName(namespace: namespaceURI ?? "", name: elementName)
        stack.append(name)
        text = ""
        guard stack.count <= DAVLimits.xmlDepth else {
            return fail(.tooLarge, parser)
        }
        switch stack.count {
        case 1:
            sawRoot = name == .dav("multistatus")
            if !sawRoot {
                fail(.malformed, parser)
            }
        case 2 where name == .dav("response"):
            guard result.responses.count < DAVLimits.multistatusResponses else {
                return fail(.tooLarge, parser)
            }
            response = Multistatus.Response()
        case 3 where name == .dav("propstat") && response != nil:
            propstat = Multistatus.Propstat()
        case 5 where propstat != nil && stack.dropLast().last == .dav("prop"):
            property = Multistatus.Property(name: name)
        case 6...:
            property?.descendants.insert(name)
            let known = property?.nameAttributes.count ?? 0
            if let value = attributeDict["name"], known < DAVLimits.multistatusNameAttributes {
                property?.nameAttributes.append(value)
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard let name = stack.last else {
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.count <= 3 {
            endOuter(name, value)
        } else {
            endInner(name, value)
        }
        stack.removeLast()
        text = ""
    }

    /// The end of a response, the sync token, or a response's href, status or propstat.
    private func endOuter(_ name: QName, _ value: String) {
        switch stack.count {
        case 2 where name == .dav("response"):
            if let response {
                result.responses.append(response)
            }
            response = nil
        case 2 where name == .dav("sync-token"):
            result.syncToken = value
        case 3 where name == .dav("href"):
            response?.href = value
        case 3 where name == .dav("status"):
            response?.status = Multistatus.statusCode(value)
        case 3 where name == .dav("propstat"):
            if let propstat {
                response?.propstats.append(propstat)
            }
            propstat = nil
        default:
            break
        }
    }

    /// The end of a propstat's status, a property, or an href inside a property.
    private func endInner(_ name: QName, _ value: String) {
        switch stack.count {
        case 4 where name == .dav("status"):
            propstat?.status = Multistatus.statusCode(value) ?? 0
        case 5:
            if var property {
                property.text = property.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                propstat?.properties.append(property)
            }
            property = nil
        case 6... where name == .dav("href"):
            property?.hrefs.append(value)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        property?.raw += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let string = String(bytes: CDATABlock, encoding: .utf8) ?? ""
        text += string
        property?.raw += string
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(.malformed, parser)
    }

    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?
    ) {
        fail(.malformed, parser)
    }
}
