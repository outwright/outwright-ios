// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import AuthenticationServices
import Foundation
import OutwrightSync
import UIKit

/// A provider's sign-in page in the system's authentication session, never a web view in the
/// app. Not ephemeral: an owner already signed in with the provider in Safari is not asked again.
struct SystemSignInSheet: SignInSheet {
    func present(_ url: URL, callbackScheme: String) async throws(SignInSheetError) -> URL {
        let result = await SignInSession.run(url, callbackScheme: callbackScheme)
        return try result.get()
    }
}

/// The session under way (held so it lives until it ends) and the window scene it shows over.
@MainActor
private final class SignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: ASWebAuthenticationSession?
    /// The provider of the session under way; the session holds it only weakly.
    private static var anchor: SignInSession?
    /// Counts sessions, so one that ends forgets only itself, never a newer one.
    private static var started = 0

    private let scene: UIWindowScene

    private init(scene: UIWindowScene) {
        self.scene = scene
    }

    static func run(_ url: URL, callbackScheme: String) async -> Result<URL, SignInSheetError> {
        await withCheckedContinuation { continuation in
            let answered = Once()
            let finish = { (result: Result<URL, SignInSheetError>) in
                guard answered.first() else { return }
                continuation.resume(returning: result)
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive }
            // With no window to show over, the sheet cannot appear.
            guard let scene = active ?? scenes.first else {
                finish(.failure(.failed))
                return
            }
            started += 1
            let number = started
            let callback = ASWebAuthenticationSession.Callback.customScheme(callbackScheme)
            let session = ASWebAuthenticationSession(url: url, callback: callback) { callback, error in
                if let callback {
                    finish(.success(callback))
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    finish(.failure(.cancelled))
                } else {
                    finish(.failure(.failed))
                }
                Task { @MainActor in clear(number) }
            }
            session.prefersEphemeralWebBrowserSession = false
            let provider = SignInSession(scene: scene)
            session.presentationContextProvider = provider
            current?.cancel()
            current = session
            anchor = provider
            if !session.start() {
                current = nil
                anchor = nil
                finish(.failure(.failed))
            }
        }
    }

    /// Forgets the session that ended, unless a newer one has taken its place.
    private static func clear(_ number: Int) {
        if number == started {
            current = nil
            anchor = nil
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        scene.keyWindow ?? scene.windows.first ?? UIWindow(windowScene: scene)
    }
}
