// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightGraph
import OutwrightJMAP
import OutwrightPush

/// An error's code for the diagnostics: its case names from the outermost enum to the innermost,
/// dot-joined, with any status number kept (`imap.net.timeout`, `dav.status.401`). Text a server or
/// a message put in a case (a reason, a host) is never part of it.
public func errorCode(_ error: any Error) -> String {
    code(of: error, depth: 0).joined(separator: ".")
}

/// Deep enough for every error the sync has; a cycle could never run on.
private let deepest = 8

private func code(of value: Any, depth: Int) -> [String] {
    let mirror = Mirror(reflecting: value)
    guard depth < deepest else { return [] }
    switch mirror.displayStyle {
    case .enum:
        guard let child = mirror.children.first else {
            // A case without a payload is named by its description, unless the type words one
            // itself: then by the name it gives, else by nothing that could be text.
            if let named = value as? any CaseNamed { return [named.caseName] }
            if value is any CustomStringConvertible { return ["unnamed"] }
            return [String(describing: value)]
        }
        return [child.label ?? "case"] + code(of: child.value, depth: depth + 1)
    case .tuple:
        return mirror.children.flatMap { code(of: $0.value, depth: depth + 1) }
    default:
        if let number = value as? any BinaryInteger {
            return [String(describing: number)]
        }
        return []
    }
}

/// An error enum that describes itself in words names its payload-free cases here, for the code.
protocol CaseNamed {
    var caseName: String { get }
}

extension OAuthError: CaseNamed {
    var caseName: String {
        switch self {
        case .cancelled: "cancelled"
        case .wrongState: "wrongState"
        case .refused: "refused"
        case .invalidGrant: "invalidGrant"
        case .malformed: "malformed"
        case .transport: "transport"
        case .http: "http"
        }
    }
}

extension JMAPError: CaseNamed {
    var caseName: String {
        switch self {
        case .auth: "auth"
        case .http: "http"
        case .malformed: "malformed"
        case .insecure: "insecure"
        case .refused: "refused"
        case .notFound: "notFound"
        case .transport: "transport"
        case .timeout: "timeout"
        }
    }
}

extension PushError: CaseNamed {
    var caseName: String {
        switch self {
        case .http: "http"
        case .limit: "limit"
        case .rateLimited: "rateLimited"
        case .malformed: "malformed"
        case .transport: "transport"
        case .crypto: "crypto"
        case .jmap: "jmap"
        case .attest: "attest"
        case .timeout: "timeout"
        case .noDeviceToken: "noDeviceToken"
        case .storage: "storage"
        case .mailServer: "mailServer"
        case .unsupported: "unsupported"
        case .serverRefused: "serverRefused"
        case .notSetUp: "notSetUp"
        case .unknownAddress: "unknownAddress"
        }
    }
}
