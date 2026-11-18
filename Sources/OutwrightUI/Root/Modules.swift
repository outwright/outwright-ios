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
    /// The screens of each protection, the first being the one a new message is protected with; empty:
    /// no mail protection in this build.
    public var protectionScreens: [any ProtectionUI] = []
    /// How stored mail that is protected from readers is opened, asked in order (the first to answer wins).
    public var openings: [any MessageOpening] = []
    /// What the modules add to an attachment's menu.
    public var attachmentActions: [any AttachmentAction] = []
    /// Sections the modules add to an account's settings.
    public var accountSections: [any AccountSection] = []
    /// What this build offers where push from an account's server is not on; nil: nothing.
    public var pushAlternative: (any PushAlternative)?
    /// What this build offers to whom; nil: everything is included.
    public var offering: (any Offering)?
    /// Sections the modules add to the app's Settings.
    public var settingsSections: [any SettingsSection] = []
    /// What the modules report needs the owner's attention, per account.
    public var attention: [any AccountAttention] = []
    /// Parts of the setup file the modules add (their keys, their accounts' extras), beside the
    /// ones the open core carries.
    public var setupParts: [any SetupPart] = []

    public init(
        providers: [any AccountProvider] = [], protections: [any MailProtection] = [],
        protectionScreens: [any ProtectionUI] = [], openings: [any MessageOpening] = []
    ) {
        self.providers = providers
        self.protections = protections
        self.protectionScreens = protectionScreens
        self.openings = openings
    }

    /// The screens of the protection `id` names (nil: the first, for what carries no id).
    @MainActor public func screens(for id: ProtectionID?) -> (any ProtectionUI)? {
        guard let id else { return protectionScreens.first }
        return protectionScreens.first { $0.protection == id }
    }
}
