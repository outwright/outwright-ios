// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Synchronization

/// One HTTP answer: its status, the URL that gave it (after redirects), its headers with
/// lower-cased names, and its body.
struct HTTPReply: Sendable {
    let status: Int
    let url: URL
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Which hosts a request may go to, and in which scheme.
enum Hosts {
    static func normalize(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = normalize(host)
        if host == "localhost" || host == "::1" || host == "[::1]" {
            return true
        }
        // 127.0.0.0/8 written as four decimal octets; a name such as 127.example.org is not.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127"
            && octets.allSatisfy { $0.count <= 3 && $0.allSatisfy(\.isASCII) && UInt8($0) != nil }
    }

    /// HTTPS anywhere; plain HTTP only to loopback.
    static func schemeAllowed(_ url: URL) -> Bool {
        guard let host = url.host(), !host.isEmpty else {
            return false
        }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return isLoopback(host)
        default: return false
        }
    }
}

/// HTTP over `URLSession` with the redirects followed by hand: only to trusted hosts, and
/// Basic authentication only on requests to a trusted host. Bodies are read with a cap.
struct HTTPClient: Sendable {
    let credentials: DAVCredentials?
    /// Normalized host names; nil follows redirects anywhere (only without credentials).
    let trustedHosts: Set<String>?
    let session: URLSession
    /// Most body bytes read; 0 reads the headers only.
    var bodyLimit = DAVLimits.responseBytes

    init(credentials: DAVCredentials?, trustedHosts: Set<String>?, session: URLSession) {
        self.credentials = credentials
        self.trustedHosts = trustedHosts.map { Set($0.map(Hosts.normalize)) }
        self.session = session
    }

    func trusts(_ url: URL) -> Bool {
        guard let host = url.host() else {
            return false
        }
        return trustedHosts?.contains(Hosts.normalize(host)) ?? (credentials == nil)
    }

    func send(
        _ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil
    ) async throws(DAVError) -> HTTPReply {
        var target = url
        var method = method
        var body = body
        var last = 0
        for _ in 0...DAVLimits.redirects {
            guard Hosts.schemeAllowed(target) else {
                throw .plainRefused
            }
            let reply = try await once(method, target, headers, body)
            guard [301, 302, 303, 307, 308].contains(reply.status) else {
                return reply
            }
            last = reply.status
            guard let location = reply.header("location"),
                let next = URL(string: location, relativeTo: target)?.absoluteURL
            else {
                throw .malformed
            }
            guard trusts(next) else {
                throw .offDomainRedirect(host: next.host() ?? "")
            }
            if reply.status == 303 {
                method = "GET"
                body = nil
            }
            target = next
        }
        throw .status(last)
    }

    private func once(
        _ method: String, _ url: URL, _ headers: [String: String], _ body: Data?
    ) async throws(DAVError) -> HTTPReply {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(Self.clean(value), forHTTPHeaderField: name)
        }
        if let credentials, trusts(url) {
            request.setValue(credentials.basic, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return try await Transfer.run(request, url: url, session: session, limit: bodyLimit).get()
    }

    /// A header value with CR, LF and NUL taken out (values can come from the server).
    static func clean(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
    }
}

/// One data task with its own delegate: no automatic redirect, no stored credentials, and
/// the body cut off past `limit`.
final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var body = Data()
        var response: HTTPURLResponse?
        var overflow = false
        /// The server asked for credentials; answered as a 401 without a retry.
        var challenged = false
        var continuation: CheckedContinuation<Result<HTTPReply, DAVError>, Never>?
        /// The outcome, when the task ended before the continuation was stored.
        var result: Result<HTTPReply, DAVError>?
    }

    private let state = Mutex(State())
    private let limit: Int
    private let url: URL

    private init(limit: Int, url: URL) {
        self.limit = limit
        self.url = url
    }

    static func run(
        _ request: URLRequest, url: URL, session: URLSession, limit: Int
    ) async -> Result<HTTPReply, DAVError> {
        guard !Task.isCancelled else {
            return .failure(.net)
        }
        let transfer = Transfer(limit: limit, url: url)
        let task = session.dataTask(with: request)
        task.delegate = transfer
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The task may already have ended (cancelled first): then answer at once.
                let early = transfer.state.withLock { state in
                    if state.result == nil {
                        state.continuation = continuation
                    }
                    return state.result
                }
                if let early {
                    continuation.resume(returning: early)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Credentials are only ever sent up front; never from a store, never on a retry.
            state.withLock { $0.challenged = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let tooLarge = limit > 0 && response.expectedContentLength > Int64(limit)
        state.withLock {
            $0.response = response
            $0.overflow = tooLarge
        }
        completionHandler(limit == 0 || tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = self.limit
        let overflow = state.withLock { state in
            state.body.append(data)
            if state.body.count > limit {
                state.overflow = true
                state.body = Data()
            }
            return state.overflow
        }
        if overflow {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let headersOnly = limit == 0
        let url = self.url
        let (continuation, result) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            let result: Result<HTTPReply, DAVError>
            if state.overflow {
                result = .failure(.tooLarge)
            } else if state.challenged, state.response == nil {
                result = .success(HTTPReply(status: 401, url: url, headers: [:], body: Data()))
            } else if let response = state.response, error == nil || headersOnly {
                result = .success(Self.reply(response, url: url, body: state.body))
            } else {
                result = .failure(.net)
            }
            if continuation == nil {
                state.result = result
            }
            return (continuation, result)
        }
        continuation?.resume(returning: result)
    }

    /// Contact data is never written to a URL cache, in memory or on disk.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func reply(_ response: HTTPURLResponse, url: URL, body: Data) -> HTTPReply {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return HTTPReply(status: response.statusCode, url: url, headers: headers, body: body)
    }
}
