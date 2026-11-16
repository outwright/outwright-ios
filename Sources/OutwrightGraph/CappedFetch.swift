// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The hosts plain http may go to: loopback only, where the tests' fakes run.
public enum Loopback {
    public static let hosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
}

/// One request to the sign-in or Graph: never redirected (a token or code would go with it, so the 3xx
/// itself comes back), and its body cut off past a limit.
enum CappedFetch {
    enum Failure: Error {
        case tooLarge, notHTTP, transport
    }

    /// The status and at most `limit` bytes of body.
    static func run(
        _ request: URLRequest, session: URLSession, limit: Int
    ) async -> Result<(status: Int, body: Data), Failure> {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else {
                return .failure(.notHTTP)
            }
            if http.expectedContentLength > Int64(limit) {
                return .failure(.tooLarge)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    return .failure(.tooLarge)
                }
            }
            return .success((http.statusCode, data))
        } catch {
            return .failure(.transport)
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
