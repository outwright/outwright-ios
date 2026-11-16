// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftUI

/// The features of the open code a build may offer to some users only.
public enum OfferedFeature: String, Sendable, CaseIterable {
    /// New mail announced at once through the push relay.
    case push
}

/// What a build offers: whether a feature is included for this user, and what is shown where one
/// is not. A build without one includes everything and shows nothing of it.
@MainActor public protocol Offering: AnyObject {
    func includes(_ feature: OfferedFeature) -> Bool
    /// Shown under a feature that is not included, before the link to `page()`.
    func note(for feature: OfferedFeature) -> Text
    /// The title of the link to `page()`.
    func linkTitle() -> Text
    /// What is included and how to get the rest.
    func page() -> AnyView
}

/// A section a module adds to the app's Settings.
@MainActor public protocol SettingsSection: AnyObject {
    func section() -> AnyView
}
