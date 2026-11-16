// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
public import OutwrightSync

/// A provider as the interface sees it: its place in Add account, and its sign-in. A build's
/// composition registers its providers (`Modules.providers`); the interface asks them and never
/// names one. Texts come already in the interface's language.
@MainActor
public protocol AccountProvider: Provider {
    /// The Add account button.
    var addTitle: String { get }
    /// Under the button, if anything.
    var addNote: String? { get }
    /// The button's accessibility identifier, for the end-to-end tests.
    var addIdentifier: String { get }
    /// The header over Sign in again in an account's settings.
    var signInHeader: String { get }
    /// A sign-in for adding an account or signing one in again; nil when the provider can't.
    func signIn(app: AppModel) -> (any ProviderSignIn)?
    /// Whether `address` is this provider's, so Add account signs in with it instead of looking
    /// up the owner's own server. Only the domain may be looked up, through `resolver`.
    func claims(_ address: String, resolver: any DoHResolving) async -> Bool
}

/// Why a provider's sign-in did not end in an account.
public enum ProviderSignInError: Error, Equatable, Sendable {
    /// The owner closed the sheet: nothing to say.
    case cancelled
    /// What to tell the owner, in the interface's language.
    case failed(String)
}

/// A provider's sign-in under way: adding an account, or signing one in again.
@MainActor
public protocol ProviderSignIn: AnyObject {
    var isSigningIn: Bool { get }
    /// `hint` is the address the owner typed, when there is one.
    func addAccount(hint: String?) async throws(ProviderSignInError) -> Account
    func signInAgain(_ account: Account) async throws(ProviderSignInError)
}
