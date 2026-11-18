// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Network

/// The device that scans the code: finds the other device and connects to it.
public enum SetupConnector {
    /// Browses for `_outwright-setup._tcp` and connects to the device advertised as `service`; `.timedOut` when that
    /// does not succeed `within` the time. A refused local network permission finds nothing, so it too shows up as
    /// `.timedOut` after `within`.
    public static func connect(
        service: String, within: Duration = .seconds(30)
    ) async throws(SetupError) -> any SetupStream {
        try await SetupLink.deadline(within) { () async throws(SetupError) -> any SetupStream in
            let endpoint = try await browse(for: service)
            let link = SetupLink(NWConnection(to: endpoint, using: SetupLink.parameters()), failOnWaiting: false)
            try await link.open()
            return link
        }
    }

    /// Connects straight to `host` and `port`, for tests over loopback: `.connectionLost` at once when refused or
    /// unreachable, `.timedOut` when the attempt hangs past `within`.
    public static func connect(
        host: String, port: UInt16, within: Duration = .seconds(30)
    ) async throws(SetupError) -> any SetupStream {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw .malformed }
        return try await SetupLink.deadline(within) { () async throws(SetupError) -> any SetupStream in
            let link = SetupLink(
                NWConnection(host: NWEndpoint.Host(host), port: port, using: SetupLink.parameters()),
                failOnWaiting: true)
            try await link.open()
            return link
        }
    }

    private static func browse(for service: String) async throws(SetupError) -> NWEndpoint {
        let found = Outcome<NWEndpoint>()
        let browser = NWBrowser(
            for: .bonjour(type: SetupLink.serviceType, domain: nil), using: SetupLink.parameters())
        browser.browseResultsChangedHandler = { results, _ in
            let match = results.first { result in
                if case let .service(name, _, _, _) = result.endpoint { return name == service }
                return false
            }
            if let match { found.resolve(.success(match.endpoint)) }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: found.resolve(.failure(.connectionLost))
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "outwright.setup.browser"))
        let result = await withTaskCancellationHandler {
            await found.value()
        } onCancel: {
            found.resolve(.failure(.connectionLost))
        }
        browser.cancel()
        return try result.get()
    }
}
