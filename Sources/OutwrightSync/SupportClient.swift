// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
import OutwrightNet

public struct SupportSubmission: Codable, Sendable {
    public var email: String
    public var message: String
    public var diagnostics: Data?

    public init(email: String, message: String, diagnostics: Data?) {
        self.email = email
        self.message = message
        self.diagnostics = diagnostics
    }
}

public enum SupportSendError: Error, Equatable {
    case invalidRequest, reportTooLarge, rateLimited, failed
}

private struct SupportReceipt: Decodable {
    var accepted: Bool
    enum CodingKeys: String, CodingKey { case accepted = "ok" }
}

/// Sends support through the website, independently of the owner's mail accounts.
public struct SupportClient: Sendable {
    private let endpoint: URL?

    public init(endpoint: URL? = URL(string: "https://outwright.app/api/support")) {
        self.endpoint = endpoint
    }

    public func send(_ submission: SupportSubmission) async throws(SupportSendError) {
        guard let endpoint,
            endpoint.scheme == "https"
                || (endpoint.scheme == "http" && ["127.0.0.1", "::1", "localhost"].contains(endpoint.host ?? ""))
        else { throw .failed }
        guard (submission.diagnostics?.count ?? 0) <= 256 * 1024 else { throw .reportTooLarge }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(submission)
            let (bytes, response) = try await HTTPSession.shared.bytes(for: request)
            try checkStatus(response)
            var body = Data()
            for try await byte in bytes {
                guard body.count < 4096 else { throw SupportSendError.failed }
                body.append(byte)
            }
            guard try JSONDecoder().decode(SupportReceipt.self, from: body).accepted
            else { throw SupportSendError.failed }
        } catch let error as SupportSendError {
            throw error
        } catch {
            throw .failed
        }
    }

    private func checkStatus(_ response: URLResponse) throws(SupportSendError) {
        guard let response = response as? HTTPURLResponse else { throw .failed }
        switch response.statusCode {
        case 400: throw .invalidRequest
        case 429: throw .rateLimited
        case 200: break
        default: throw .failed
        }
    }
}
