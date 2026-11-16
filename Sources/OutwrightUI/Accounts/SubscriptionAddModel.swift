// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import OutwrightModel
import OutwrightSync

/// Adding a subscribed calendar: the address is checked (fetched and read once) before it can be
/// saved; a changed address needs a new check. The name comes from the file unless one is typed.
@Observable @MainActor
final class SubscriptionAddModel {
    enum State: Equatable {
        case editing
        case checking
        case checked(SubscriptionPreview)
        case failed(SubscriptionAddError)
        case saving
    }

    let app: AppModel
    var address = "" {
        didSet { if address != oldValue { state = .editing } }
    }
    var name = ""
    var color: Int?
    private(set) var state = State.editing

    init(app: AppModel) {
        self.app = app
    }

    var canSave: Bool {
        if case .checked = state { return true }
        return false
    }

    /// Checks the address as it is now; an answer for an address since changed is dropped.
    func check() async {
        let checked = address
        state = .checking
        do {
            let preview = try await app.checkSubscription(checked)
            guard address == checked else { return }
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let found = preview.name { name = found }
            state = .checked(preview)
        } catch {
            guard address == checked else { return }
            state = .failed(error)
        }
    }

    /// The new calendar, or nil when it was not checked or could not be kept.
    func save() async -> CalendarID? {
        guard case let .checked(preview) = state else { return nil }
        state = .saving
        let title = name.trimmingCharacters(in: .whitespaces)
        do {
            return try await app.addSubscription(
                address, name: title.isEmpty ? (preview.name ?? "Calendar") : title, color: color)
        } catch {
            state = .failed(error)
            return nil
        }
    }
}
