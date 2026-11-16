// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Server entries of IMAP METADATA (RFC 5464), off unless a test offers them.
extension FakeIMAPServer {
    public func offerMetadata(_ offered: Bool) {
        offersMetadata = offered
    }

    /// Every later SETMETADATA is answered NO, as a server whose owner turned writes off.
    public func refuseMetadataWrites() {
        refusesMetadataWrites = true
    }

    /// Every later GETMETADATA and SETMETADATA is answered NO with `text` (nil: answered again).
    public func failMetadata(with text: String?) {
        metadataFailure = text
    }

    /// Runs `handler` for every APPEND after the message is stored and before it is answered,
    /// with the folder and the message: a server's push script sees appends that way.
    public func onAppend(_ handler: @escaping @Sendable (_ path: String, _ data: Data) async -> Void) {
        appendHandlers.append(handler)
    }

    /// `GETMETADATA [(DEPTH infinity)] "" (names)` or `… "" name`: server entries only.
    func getMetadata(_ id: Int, _ tag: String, _ arguments: [Token]) {
        if let metadataFailure {
            reply(id, "\(tag) NO \(metadataFailure)")
            return
        }
        var rest = arguments[...]
        var deep = false
        if case let .list(options)? = rest.first {
            deep = options.compactMap(\.text).map { $0.uppercased() }.contains("INFINITY")
            rest = rest.dropFirst()
        }
        guard rest.first?.text == "", let requested = rest.dropFirst().first else {
            reply(id, "\(tag) BAD Only server entries")
            return
        }
        let names: [String]
        if case let .list(items) = requested {
            names = items.compactMap(\.text)
        } else {
            names = requested.text.map { [$0] } ?? []
        }
        var found: [(String, String)] = []
        for name in names {
            if let value = serverMetadata[name] {
                found.append((name, value))
            }
            if deep {
                let prefix = name.hasSuffix("/") ? name : name + "/"
                found += serverMetadata.filter { $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value) }
            }
        }
        if !found.isEmpty {
            let pairs = found.sorted { $0.0 < $1.0 }.map { "\(Self.quoted($0.0)) \(Self.quoted($0.1))" }
            reply(id, "* METADATA \"\" (\(pairs.joined(separator: " ")))")
        }
        reply(id, "\(tag) OK GETMETADATA completed")
    }

    /// `SETMETADATA "" (name value …)`, NIL removing.
    func setMetadata(_ id: Int, _ tag: String, _ arguments: [Token]) {
        guard arguments.first?.text == "", case let .list(items)? = arguments.dropFirst().first,
              items.count.isMultiple(of: 2)
        else {
            reply(id, "\(tag) BAD SETMETADATA needs server entries")
            return
        }
        if let metadataFailure {
            reply(id, "\(tag) NO \(metadataFailure)")
            return
        }
        guard !refusesMetadataWrites else {
            reply(id, "\(tag) NO [METADATA NOPRIVATE] Not allowed")
            return
        }
        var index = 0
        while index + 1 < items.count {
            guard let name = items[index].text else {
                reply(id, "\(tag) BAD Entry names are strings")
                return
            }
            if case let .atom(atom) = items[index + 1], atom.uppercased() == "NIL" {
                serverMetadata[name] = nil
            } else {
                serverMetadata[name] = items[index + 1].text
            }
            index += 2
        }
        reply(id, "\(tag) OK SETMETADATA completed")
    }
}
