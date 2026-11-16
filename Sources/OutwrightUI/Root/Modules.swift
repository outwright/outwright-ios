// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel
public import OutwrightSync

/// What a build is made of beyond the open core: the providers and hooks its composition
/// registers at launch. Each build's spec adds exactly one composition; the shared code asks
/// this and never names a module.
public struct Modules {
    /// The providers accounts can be added with, besides the owner's own server.
    public var providers: [any AccountProvider] = []

    /// The ways of protecting mail the sync asks when a draft asks for one.
    public var protections: [any MailProtection] = []
    /// The screens of a protection; nil: no mail protection in this build.
    public var protectionUI: (any ProtectionUI)?
    /// How stored mail that is protected from readers is opened.
    public var opening: (any MessageOpening)?
    /// Sections the modules add to an account's settings.
    public var accountSections: [any AccountSection] = []
    /// What this build offers to whom; nil: everything is included.
    public var offering: (any Offering)?
    /// Sections the modules add to the app's Settings.
    public var settingsSections: [any SettingsSection] = []

    public init(
        providers: [any AccountProvider] = [], protections: [any MailProtection] = [],
        protectionUI: (any ProtectionUI)? = nil, opening: (any MessageOpening)? = nil
    ) {
        self.providers = providers
        self.protections = protections
        self.protectionUI = protectionUI
        self.opening = opening
    }
}
