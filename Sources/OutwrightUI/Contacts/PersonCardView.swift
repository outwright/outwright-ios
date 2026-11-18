// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import OutwrightModel
import SwiftUI

/// A person: avatar, name, organisation, call, mail and message, the details, the latest mail
/// with them and the events with them; Edit at the top right, and when a change was not taken, how
/// to go on.
struct PersonCardView: View {
    /// Where the card stands, which decides its top left button.
    enum Presentation {
        /// Over whatever opened it (an address in a message): ✕.
        case sheet
        /// Beside the contact list on a wide screen: nothing.
        case pane
        /// Pushed over the contact list in one column: back.
        case pushed
    }

    let app: AppModel
    @State private var model: PersonCardModel
    @State private var showsAllDetails = false
    @State private var showsAllMessages = false
    @State private var actionFailed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let presentation: Presentation

    init(app: AppModel, request: PersonRequest, presentation: Presentation = .sheet) {
        self.app = app
        self.presentation = presentation
        _model = State(initialValue: PersonCardModel(app: app, request: request))
    }

    var body: some View {
        // The bar stands above the scroll view, not over it: on iOS 26 the scroll view's top edge
        // takes the taps meant for buttons laid over it (Edit did nothing on an iPad and a Mac).
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    if model.failed {
                        ProblemBanner(text: L10n.string("The contact couldn't be read. Try again."))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    }
                    if actionFailed {
                        ProblemBanner(text: L10n.string("The contact couldn't be saved. Try again."))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    }
                    header
                    if model.conflict != nil { conflictBanner }
                    if model.changeFailed && model.conflict == nil { failedBanner }
                    quickButtons
                    if model.canAddContact { addContact }
                    details
                    if let address = model.mailAddress?.email {
                        ForEach(Array(app.modules.protectionScreens.enumerated()), id: \.offset) { _, screens in
                            screens.personSection(for: address)
                        }
                    }
                    messages
                    if !model.events.isEmpty { events }
                    if !model.files.isEmpty { PersonCardFiles(files: model.files, app: app) }
                }
                .padding(16)
            }
            .refreshable { await model.pull() }
        }
        .background(Theme.drawerBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await model.observe() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let contact = model.contact {
                ContactAvatar(contact: contact, size: 96)
            } else {
                Avatar(name: model.name, email: model.emails.first?.value ?? model.name, size: 96)
            }
            Text(verbatim: model.name).font(.title2.bold()).multilineTextAlignment(.center)
            let role = [model.title, model.organization].filter { !$0.isEmpty }.joined(separator: " · ")
            if !role.isEmpty {
                Text(verbatim: role).font(.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
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
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// A card sheet closes first; compose opens once it is gone.
    private func mail() {
        model.mail()
    }

    /// Leads into the new-contact editor with the address filled in (once a card sheet has closed).
    private var addContact: some View {
        Button {
            if let address = model.mailAddress {
                let back = presentation == .sheet
                app.afterCard { [app] in
                    app.contactEditor = ContactEditorRequest(prefill: address, returnsToCard: back)
                }
            }
        } label: {
            ModuleLabel("Add contact", systemImage: Icons.personAdd).frame(maxWidth: .infinity, minHeight: 44)
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

    /// The change the server did not take, sending it again when it is a photo, and giving it up
    /// for the server's version.
    private var failedBanner: some View {
        HStack(spacing: 0) {
            ProblemBanner(
                text: model.photoFailed
                    ? L10n.string("The photo couldn't be saved to the server") : L10n.string("Could not be saved"))
            if model.photoFailed {
                Button { attempt { try model.retryPhoto() } } label: { Text(ui: "Retry") }
                    .buttonStyle(.bordered)
                    .padding(.leading, 8)
                    .accessibilityIdentifier("card.retryPhoto")
            }
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
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
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
            SectionHeader("Latest messages")
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
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PersonCardView {
    /// The coming events with the person, then the past ones; a tap opens one.
    private var events: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Events")
            VStack(spacing: 0) {
                ForEach(Array(model.events.enumerated()), id: \.offset) { index, event in
                    Button {
                        app.afterCard { [app] in app.eventToShow = EventRequest(event) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: event.occurrence.details.title.isEmpty
                                ? L10n.string("(No title)") : event.occurrence.details.title)
                                .font(.body).lineLimit(1)
                            let when = SearchEventRow.when(event.occurrence, now: app.now(), in: .autoupdatingCurrent)
                            Text(verbatim: when)
                                .font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < model.events.count - 1 { Divider().padding(.leading, 14) }
                }
            }
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ✕ on a sheet, back when pushed, nothing beside the list; Edit on the right when the contact's
    /// book can be written to.
    private var topBar: some View {
        HStack {
            switch presentation {
            case .sheet: GlassIconButton(Icons.close, label: "Close") { app.personToShow = nil }
            case .pushed: GlassIconButton(Icons.back, label: "Back") { dismiss() }
            case .pane: EmptyView()
            }
            Spacer(minLength: 0)
            if model.canEdit, let id = model.contact?.id {
                GlassIconButton(Icons.edit, label: "Edit contact", tint: Theme.accent) {
                    let back = presentation == .sheet
                    app.afterCard { [app] in
                        app.contactEditor = ContactEditorRequest(editing: id, returnsToCard: back)
                    }
                }
            }
        }
        .padding(16)
    }
}
