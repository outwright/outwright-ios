// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// The session every HTTP client uses by default (CalDAV, CardDAV, Graph, OAuth, JMAP, the push relay):
/// nothing a server sends is kept outside the store, so no URL cache, and no cookies or credentials
/// kept on disk.
public enum HTTPSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
