// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A person: avatar, name, organisation, call, mail and message, the details, the latest mail
/// with them; Edit and Delete, and when a change was not taken, how to go on.
struct PersonCardView: View {
    let app: AppModel
    @State private var model: PersonCardModel
    @State private var showsAllDetails = false
    @State private var showsAllMessages = false
    @State private var confirmsDelete = false
    @State private var actionFailed = false
    @Environment(\.openURL) private var openURL
    /// Beside the contact list on a wide screen rather than a sheet: no close button.
    let inPane: Bool

    init(app: AppModel, request: PersonRequest, inPane: Bool = false) {
        self.app = app
        self.inPane = inPane
        _model = State(initialValue: PersonCardModel(app: app, request: request))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.failed {
                    ProblemBanner(text: L10n.string("The contact couldn't be read. Try again."))
                }
                if actionFailed {
                    ProblemBanner(text: L10n.string("The contact couldn't be saved. Try again."))
                }
                header
                if model.conflict != nil { conflictBanner }
                if model.changeFailed && model.conflict == nil { failedBanner }
                quickButtons
                if model.canAddContact { addContact }
                details
                if let screens = app.modules.protectionUI, let address = model.mailAddress?.email {
                    screens.personSection(for: address)
                }
                messages
                if !model.files.isEmpty { PersonCardFiles(files: model.files, app: app) }
                if model.canEdit { actions }
            }
            .padding(16)
        }
        .background(Theme.drawerBackground)
        .overlay(alignment: .topTrailing) {
            if !inPane { closeButton }
        }
        .task { await model.observe() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let contact = model.contact {
                ContactAvatar(contact: contact, size: 96)
            } else {
                Avatar(name: model.name, email: model.emails.first?.value ?? model.name, size: 96)
            }
            Text(verbatim: model.name).font(.title.bold()).multilineTextAlignment(.center)
            if !model.organization.isEmpty {
                Text(verbatim: model.organization).font(.body).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    private var quickButtons: some View {
        HStack(spacing: 12) {
            quick("Call", Icons.phone, enabled: model.callURL != nil) {
                if let url = model.callURL { openURL(url) }
            }
            quick("Mail", Icons.mail, enabled: model.mailAddress != nil) { mail() }
            quick("Message", Icons.message, enabled: model.messageURL != nil) {
                if let url = model.messageURL { openURL(url) }
            }
        }
    }

    private func quick(
        _ title: LocalizedStringKey, _ icon: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).frame(height: 28)
                Text(ui: title).font(.footnote)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(enabled ? Theme.accent : Theme.secondaryText.opacity(0.6))
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// The card closes first; the compose sheet opens once it is gone.
    private func mail() {
        model.mail()
        app.personToShow = nil
    }

    /// Leads into the new-contact editor with the address filled in, once the card has closed.
    private var addContact: some View {
        Button {
            if let address = model.mailAddress {
                app.pendingContactEditor = ContactEditorRequest(prefill: address)
                app.personToShow = nil
            }
        } label: {
            ModuleLabel("Add contact", systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    // swiftlint:disable:next line_length
    private static let conflictMessage: LocalizedStringKey = "The contact was changed on the server meanwhile. Apply your change again on top of the new version, or discard it."

    private var conflictBanner: some View {
        ConflictBanner(
            title: "Your change was not saved",
            message: Self.conflictMessage,
            primary: ("Apply again", { attempt { try model.applyAgain() } }),
            secondary: ("Discard", { attempt { try model.discard() } }))
    }

    /// The change the server did not take, and giving it up for the server's version.
    private var failedBanner: some View {
        HStack(spacing: 0) {
            ProblemBanner(text: L10n.string("Could not be saved"))
            Button(role: .destructive) { attempt { try model.discardFailedChange() } } label: {
                Text(ui: "Discard")
            }
            .buttonStyle(.bordered)
            .padding(.leading, 8)
            .accessibilityIdentifier("card.discardFailed")
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            actionFailed = false
        } catch {
            actionFailed = true
        }
    }

    private var details: some View {
        let emails = showsAllDetails ? model.emails : Array(model.emails.prefix(2))
        let phones = showsAllDetails ? model.phones : Array(model.phones.prefix(2))
        let places = showsAllDetails ? (model.contact?.details.addresses ?? []) : []
        let note = showsAllDetails ? (model.contact?.details.note ?? "") : ""
        let hasMore = model.emails.count > 2 || model.phones.count > 2
            || !(model.contact?.details.addresses ?? []).isEmpty || !(model.contact?.details.note ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(phones.enumerated()), id: \.offset) { _, item in
                detailRow(item.label, item.value)
            }
            ForEach(Array(emails.enumerated()), id: \.offset) { _, item in
                detailRow(item.label, item.value)
            }
            ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                detailRow(place.label, Self.format(place))
            }
            if !note.isEmpty { detailRow(L10n.string("Note"), note) }
            if hasMore {
                Button { withAnimation { showsAllDetails.toggle() } } label: {
                    Text(ui: showsAllDetails ? "Show less" : "Show all").font(.body)
                }
                .padding(14)
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty { Text(verbatim: label).font(.footnote).foregroundStyle(Theme.secondaryText) }
            Text(verbatim: value).font(.body).textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func format(_ place: PostalAddress) -> String {
        let town = [place.postalCode, place.locality].filter { !$0.isEmpty }.joined(separator: " ")
        return [place.street, town, place.region, place.country].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ui: "Latest messages").font(.headline)
            let shown = showsAllMessages ? model.messages : model.latest
            if shown.isEmpty {
                Text(ui: "No messages with this person.").foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { row in
                        Button {
                            app.personToShow = nil
                            app.selectedTab = .mail
                            app.messageToOpen = row.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(verbatim: row.subject.isEmpty ? L10n.string("(No subject)") : row.subject)
                                        .font(.body).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(DaySections.rowLabel(row.date, now: Date(), calendar: .autoupdatingCurrent))
                                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                                }
                                Text(verbatim: row.shownPreview()).font(.subheadline)
                                    .foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 14)
                    }
                    if model.messages.count > 3 {
                        Button { withAnimation { showsAllMessages.toggle() } } label: {
                            Text(ui: showsAllMessages ? "Show less" : "Show all")
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Theme.accent)
                    }
                }
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button {
                if let id = model.contact?.id {
                    app.pendingContactEditor = ContactEditorRequest(editing: id)
                    app.personToShow = nil
                }
            } label: {
                ModuleLabel("Edit contact", systemImage: Icons.edit).frame(maxWidth: .infinity, minHeight: 44)
            }
            Divider()
            Button(role: .destructive) { confirmsDelete = true } label: {
                ModuleLabel("Delete contact", systemImage: Icons.delete).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            Text(ui: "Delete this contact?"), isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                attempt {
                    try model.delete()
                    app.personToShow = nil
                }
            } label: {
                Text(ui: "Delete contact")
            }
            Button(role: .cancel) {} label: { Text(ui: "Cancel") }
        } message: {
            Text(ui: "The contact is deleted from its address book.")
        }
    }
}

extension PersonCardView {
    /// Closes the sheet.
    fileprivate var closeButton: some View {
        Button { app.personToShow = nil } label: {
            Image(systemName: Icons.close)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(16)
        .accessibilityLabel(Text(ui: "Close"))
    }
}
