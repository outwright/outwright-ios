// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightIMAP
import OutwrightMIME
public import OutwrightModel
import Synchronization

/// One new message as a notification shows it.
public struct NewMail: Sendable, Equatable {
    public var sender: String
    public var subject: String
    /// The message is protected from readers: its outer subject says nothing and is never shown.
    public var isProtected: Bool

    public init(sender: String, subject: String, isProtected: Bool = false) {
        self.sender = sender
        self.subject = subject
        self.isProtected = isProtected
    }
}

/// What a probe found.
public enum ProbeResult: Sendable, Equatable {
    /// New unseen mail: up to five, newest first, and how many there are in all.
    case mail([NewMail], count: Int)
    /// Nothing to announce (nothing new, already announced, or an unknown subscription).
    case nothing
    /// The server could not be asked in time; the notification keeps its generic text.
    case failed
}

/// Asks an account's Inbox, from the phone, what came since the subscription's watermark: run
/// by the notification extension when a push arrives. Only unseen mail above the mark counts,
/// and each UID is claimed once, however many probes run.
public struct NewMailProbe: Sendable {
    static let shown = 5
    /// At most this many new UIDs are looked at (the newest); more still count.
    static let examined = 500
    static let maxText = 256

    private let account: @Sendable (String) -> Account?
    private let credentials: CredentialProvider
    private let marks: PushWatermarks

    /// `account` maps a subscription id to its account; nil for one no longer known.
    public init(
        account: @escaping @Sendable (String) -> Account?, secrets: any SecretStore, marks: PushWatermarks
    ) {
        self.init(account: account, credentials: CredentialProvider(secrets: secrets), marks: marks)
    }

    public init(
        account: @escaping @Sendable (String) -> Account?, credentials: CredentialProvider, marks: PushWatermarks
    ) {
        self.account = account
        self.credentials = credentials
        self.marks = marks
    }

    /// Never throws: any failure, or the budget running out, is `.failed`. Running out closes
    /// the connection.
    public func run(subscriptionID: String, budget: Duration = .seconds(20)) async -> ProbeResult {
        guard let account = account(subscriptionID) else {
            return .nothing
        }
        let held = Held()
        let outcome = Once()
        let work = Task {
            let result: ProbeResult
            do {
                result = try await probe(subscriptionID, account: account, held: held)
            } catch {
                result = .failed
            }
            await outcome.finish(result)
        }
        let timer = Task {
            try? await Task.sleep(for: budget)
            await outcome.finish(.failed)
        }
        let result = await outcome.value()
        timer.cancel()
        work.cancel()
        if let client = held.take() {
            if result == .failed {
                await client.close()
            } else {
                await client.logout()
            }
        }
        return result
    }

    /// Puts the mark at the Inbox's newest message, so nothing already there is announced.
    public func start(subscriptionID: String, account: Account) async throws(SyncError) {
        let client = try await signIn(account)
        let mark: PushWatermark
        do {
            let status = try await imap { try await client.select("INBOX") }
            mark = try await Self.mark(account, status, client)
        } catch {
            await client.logout()
            throw error
        }
        await client.logout()
        try marks.set(mark, for: subscriptionID)
    }

    private func probe(
        _ subscriptionID: String, account: Account, held: Held
    ) async throws(SyncError) -> ProbeResult {
        let client = try await signIn(account)
        guard held.put(client) else {
            await client.close()
            return .failed
        }
        let status = try await imap { try await client.select("INBOX") }
        guard let mark = try marks.get(subscriptionID), mark.uidValidity == status.uidValidity,
            mark.accountID == account.id
        else {
            // New, renumbered or another account's: start again from now, announcing nothing.
            try marks.set(try await Self.mark(account, status, client), for: subscriptionID)
            return .nothing
        }
        let above = try await imap { try await client.uids(above: mark.lastUID) }
        guard !above.isEmpty else {
            return .nothing
        }
        let newest = Array(above.suffix(Self.examined))
        let flags = try await imap { try await client.flags(uids: newest) }
        let unseen = newest.filter { flags[$0].map { !$0.contains("\\Seen") } ?? false }
        guard !unseen.isEmpty else {
            try marks.claim(subscriptionID, validity: status.uidValidity, uids: above)
            return .nothing
        }
        let summaries = try await imap {
            try await client.summaries(uids: Array(unseen.suffix(Self.shown).reversed()))
        }
        // Claimed last, once everything is in hand: a probe that fails leaves the mail to the next.
        let claimed = Set(try marks.claim(subscriptionID, validity: status.uidValidity, uids: above))
        let mine = unseen.filter(claimed.contains)
        guard !mine.isEmpty else {
            return .nothing
        }
        return .mail(summaries.filter { claimed.contains($0.uid) }.map(Self.newMail), count: mine.count)
    }

    private func signIn(_ account: Account) async throws(SyncError) -> IMAPClient {
        guard let endpoint = AccountSyncer.endpoint(account.imap) else {
            throw .imap(.net(.io("Unknown transport security")))
        }
        return try await credentials.connect(endpoint, account: account)
    }

    /// The mark at the Inbox's newest message: UIDNEXT - 1, or, when SELECT gave no UIDNEXT
    /// (0), the highest UID there is.
    private static func mark(
        _ account: Account, _ status: FolderStatus, _ client: IMAPClient
    ) async throws(SyncError) -> PushWatermark {
        let (last, overflow) = status.uidNext.subtractingReportingOverflow(1)
        let lastUID = overflow ? (try await imap { try await client.highestUID() } ?? 0) : last
        return PushWatermark(accountID: account.id, uidValidity: status.uidValidity, lastUID: lastUID)
    }

    static func newMail(_ summary: MessageSummary) -> NewMail {
        let parsed = RowBuilder.headers(summary)
        let from = RowBuilder.sender(parsed)
        let name = from.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let isProtected = MessageReader.isEncryptedShape(parsed)
        return NewMail(
            sender: clean(name.isEmpty ? from.email : name), subject: isProtected ? "" : clean(parsed.subject),
            isProtected: isProtected)
    }

    /// Control characters out, length capped.
    private static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(maxText))
    }
}

/// The probe's connection, for closing it when the budget runs out.
/// Once taken it stays empty: a connection that opens after the probe has ended is refused.
private final class Held: Sendable {
    private let state = Mutex<(client: IMAPClient?, ended: Bool)>((nil, false))

    /// False when the probe has already ended; the caller closes `value` then.
    func put(_ value: IMAPClient) -> Bool {
        state.withLock { state in
            guard !state.ended else {
                return false
            }
            state.client = value
            return true
        }
    }

    func take() -> IMAPClient? {
        state.withLock { state in
            state.ended = true
            return state.client.take()
        }
    }
}

/// The first result handed in wins; `value` waits for it.
private actor Once {
    private var result: ProbeResult?
    private var waiters: [CheckedContinuation<ProbeResult, Never>] = []

    func finish(_ value: ProbeResult) {
        guard result == nil else {
            return
        }
        result = value
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> ProbeResult {
        if let result {
            return result
        }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
