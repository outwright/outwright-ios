// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// Why a sign-in sheet ended without a callback.
public enum SignInSheetError: Error, Sendable, Equatable {
    /// The owner closed it.
    case cancelled
    /// It could not be shown or ended in an error.
    case failed
}

/// Shows a provider's sign-in page outside the app (the system's authentication session, never a
/// web view) and returns the callback URL it ends on.
public protocol SignInSheet: Sendable {
    func present(_ url: URL, callbackScheme: String) async throws(SignInSheetError) -> URL
}
