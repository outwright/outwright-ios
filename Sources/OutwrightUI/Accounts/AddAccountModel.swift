// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import Observation
public import OutwrightModel
public import OutwrightNet
public import OutwrightStore
public import OutwrightSync

/// Why an account was not added. Never carries the password.
public enum AddAccountError: Error, Sendable, Equatable {
    /// Address, password or a server is missing.
    case incomplete
    /// A server found for the address is outside its domain and the owner has not said yes to it.
    case serversNotConfirmed
    /// An account with this address is already on the phone.
    case alreadyAdded
    /// A server refused the sign-in, or could not be reached.
    case signIn(SyncError)
    case keychain(SyncError)
    case store
}

/// Adding an account on the owner's own server: the address, the servers its domain names
/// (RFC 6186), the password; IMAP and SMTP must both take the password before anything is kept.
@Observable @MainActor
public final class AddAccountModel {
    public var email = ""
    public var name = ""
    public var password = ""
    /// The user name for both servers; the address when left empty.
    public var user = ""
    public var imap: MailEndpoint?
    public var smtp: MailEndpoint?
    public private(set) var discovered: DiscoveredServers?
    /// What the CardDAV lookup found, so an address outside the domain is asked about.
    private var discoveredCardDAV: DAVFound?
    /// What the CalDAV lookup found, the same way.
    private var discoveredCalDAV: DAVFound?
    public private(set) var isDiscovering = false
    public private(set) var isConnecting = false
    /// Observed, like the two above: the form redraws when the owner says yes (#57).
    private var confirmedHosts: Set<String> = []

    @ObservationIgnored let store: MailStore
    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let resolver: any DoHResolving
    @ObservationIgnored let probe: @Sendable (URL) async -> URL?
    /// Whether the account has a calendar or an address book at an address (`DAVCollections.exist`).
    @ObservationIgnored let collections: @Sendable (DAVService, String, Account, Secret) async -> Bool?
    /// The CardDAV address for contacts. Switched off, or a found one blanked, is saved off, so none
    /// is looked for later; switched on and blank with nothing found, a later lookup may find one. An
    /// address appearing in an empty field switches contacts on.
    public var cardDAV = "" {
        didSet { if oldValue.isEmpty, !cardDAV.isEmpty { contactsOn = true } }
    }
    /// The CalDAV address for calendars, kept the same way as `cardDAV`.
    public var calDAV = "" {
        didSet { if oldValue.isEmpty, !calDAV.isEmpty { calendarOn = true } }
    }
    /// The Contacts switch; off keeps the address.
    public var contactsOn = false
    /// The Calendar switch, the same way.
    public var calendarOn = false

    /// `probe` asks a `/.well-known/carddav` (or `caldav`) address without credentials (`WellKnown.probe`);
    /// `collections` asks a DAV address with them, at Connect.
    public init(
        store: MailStore, secrets: any SecretStore, resolver: any DoHResolving,
        collections: @escaping @Sendable (DAVService, String, Account, Secret) async -> Bool?,
        probe: @escaping @Sendable (URL) async -> URL?
    ) {
        self.store = store
        self.secrets = secrets
        self.resolver = resolver
        self.collections = collections
        self.probe = probe
    }

    /// The lower-case domain of the address, when it has one.
    public var domain: String? { Self.domain(of: email) }

    /// The lower-case domain of `address`, when it has one.
    public static func domain(of address: String) -> String? {
        guard let atSign = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: atSign)...].trimmingCharacters(in: .whitespaces).lowercased()
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") ? domain : nil
    }

    public var isAddressValid: Bool {
        guard let atSign = email.lastIndex(of: "@") else { return false }
        return atSign != email.startIndex && domain != nil && !email.contains(where: \.isWhitespace)
    }

    /// Looks the domain's servers up (only the domain leaves the phone) and fills them in.
    public func discover() async {
        guard isAddressValid else { return }
        isDiscovering = true
        let found = await Discovery.imapAndSMTP(for: email, resolver: resolver)
        isDiscovering = false
        discovered = found
        if let found {
            imap = found.imap
            smtp = found.smtp
        }
        if user.isEmpty { user = email.trimmingCharacters(in: .whitespaces) }
        await discoverDAV()
    }

    /// The CardDAV and CalDAV addresses found for the address and the servers now filled in (RFC 6764).
    private func discoverDAV() async {
        let address = email.trimmingCharacters(in: .whitespaces)
        let none = MailEndpoint(host: "", port: 0, security: "tls")
        let probing = Account(
            id: AccountID(), displayName: address, email: address, colorIndex: 0, imap: imap ?? none,
            smtp: smtp ?? none, user: address, signature: "", sortOrder: 0)
        isDiscovering = true
        let found = await DAVDiscovery.find(.cardDAV, for: probing, resolver: resolver, probe: probe)
        discoveredCardDAV = found
        if let found { cardDAV = found.url }
        let calendars = await DAVDiscovery.find(.calDAV, for: probing, resolver: resolver, probe: probe)
        isDiscovering = false
        discoveredCalDAV = calendars
        if let calendars { calDAV = calendars.url }
    }

    /// Hosts that came from the lookup, are outside the address's domain and are still in use.
    public var hostsNeedingConfirmation: [String] {
        guard let domain else { return [] }
        // A switched-off address is not asked, so its host gets no password.
        let davHosts = [
            contactsOn ? offDomainHost(discoveredCardDAV, cardDAV) : nil,
            calendarOn ? offDomainHost(discoveredCalDAV, calDAV) : nil
        ].compactMap { $0 }
        var seen = Set<String>()
        guard let discovered, discovered.offDomain else {
            return davHosts.filter { !confirmedHosts.contains($0) && seen.insert($0).inserted }
        }
        // By host alone: a changed port or encryption still sends the password to the same host.
        let used = [(imap, discovered.imap), (smtp, discovered.smtp)].compactMap { current, found -> String? in
            guard let current, Self.sameHost(current.host, found.host) else { return nil }
            return found.host.lowercased()
        }
        let outside = used.filter { $0 != domain && !$0.hasSuffix("." + domain) } + davHosts
        return outside.filter { !confirmedHosts.contains($0) && seen.insert($0).inserted }
    }

    /// The host of a DAV address found outside the domain, while its field still names it.
    private func offDomainHost(_ found: DAVFound?, _ field: String) -> String? {
        guard let found, found.offDomain, let foundHost = URL(string: found.url)?.host(),
            let currentHost = URL(string: field.trimmingCharacters(in: .whitespaces))?.host(),
            Self.sameHost(foundHost, currentHost)
        else { return nil }
        return foundHost.lowercased()
    }

    public var needsServerConfirmation: Bool { !hostsNeedingConfirmation.isEmpty }

    static func sameHost(_ first: String, _ second: String) -> Bool {
        let trim = { (host: String) in
            host.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        }
        return trim(first) == trim(second)
    }

    /// The owner said yes to sending the password to the hosts shown.
    public func confirmServers() {
        confirmedHosts.formUnion(hostsNeedingConfirmation)
    }

    /// Signs in to IMAP and SMTP; only when both take the password is the account saved and the
    /// password put in the keychain. A CalDAV or CardDAV address with no calendar or address book
    /// behind it for this password is saved off (the address kept), to be turned on in the account's
    /// settings (#60); one that could not be asked stays on, and sync reports what is wrong.
    public func connect() async throws(AddAccountError) -> Account {
        guard isAddressValid, !password.isEmpty, let imap, let smtp,
            !imap.host.isEmpty, !smtp.host.isEmpty, imap.port > 0, smtp.port > 0
        else { throw .incomplete }
        guard !needsServerConfirmation else { throw .serversNotConfirmed }
        let address = email.trimmingCharacters(in: .whitespaces)
        let existing: [Account]
        do {
            existing = try store.accounts()
        } catch {
            throw .store
        }
        guard !existing.contains(where: { $0.email.lowercased() == address.lowercased() }) else {
            throw .alreadyAdded
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let trimmedCardDAV = keptAddress(cardDAV, on: contactsOn, found: discoveredCardDAV)
        let trimmedCalDAV = keptAddress(calDAV, on: calendarOn, found: discoveredCalDAV)
        var account = Account(
            id: AccountID(), displayName: trimmedName.isEmpty ? address : trimmedName, email: address,
            colorIndex: 0, imap: imap, smtp: smtp, user: trimmedUser.isEmpty ? address : trimmedUser,
            signature: DefaultSignature.text, sortOrder: 0, cardDAV: trimmedCardDAV,
            cardDAVOff: Self.isOff(contactsOn, trimmedCardDAV, discoveredCardDAV), calDAV: trimmedCalDAV,
            calDAVOff: Self.isOff(calendarOn, trimmedCalDAV, discoveredCalDAV)
        ).placed(after: existing, colors: Theme.avatarColors.count)
        let secret = Secret(password)
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await AccountCheck.signIn(account, password: secret)
        } catch {
            throw .signIn(error)
        }
        await keepOnlyWhatExists(&account, password: secret)
        do {
            try secrets.setPassword(secret, for: account.id)
        } catch {
            throw .keychain(error)
        }
        do {
            try store.save(account)
        } catch {
            try? secrets.remove(for: account.id)
            throw .store
        }
        password = ""
        return account
    }

    /// The address to save: none when blank, and none when switched off on a host outside the domain
    /// the owner never allowed (turned on later, it is looked up again and asked about).
    private func keptAddress(_ field: String, on switchedOn: Bool, found: DAVFound?) -> String? {
        let typed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if !switchedOn, let host = offDomainHost(found, typed), !confirmedHosts.contains(host) { return nil }
        return typed
    }

    /// Off when switched off, and when a found address was blanked; on and blank with nothing found
    /// stays on, for a later lookup.
    private static func isOff(_ switchedOn: Bool, _ address: String?, _ found: DAVFound?) -> Bool {
        !switchedOn || (address == nil && found != nil)
    }

    /// Turns off the DAV addresses the server says have nothing behind them for this account; both
    /// are asked at once.
    private func keepOnlyWhatExists(_ account: inout Account, password: Secret) async {
        let checked = account
        let ask = collections
        let calDAV = checked.calDAVOff ? nil : checked.calDAV
        let cardDAV = checked.cardDAVOff ? nil : checked.cardDAV
        async let calendars = calDAV.asyncMap { await ask(.calDAV, $0, checked, password) }
        async let contacts = cardDAV.asyncMap { await ask(.cardDAV, $0, checked, password) }
        if await calendars == false { account.calDAVOff = true }
        if await contacts == false { account.cardDAVOff = true }
    }
}

extension Optional {
    /// The value mapped by an async `transform`, or nil.
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
