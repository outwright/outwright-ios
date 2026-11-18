// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import OutwrightStore
import SwiftUI

/// Mail's header: the bell and search in the capsule; under it Focused / Other and Filter.
struct InboxHeader: View {
    @Bindable var app: AppModel
    @Bindable var inbox: InboxModel

    var body: some View {
        TabHeader(app: app, title: app.title, titleID: "inbox.title") {
            Menu {
                choice("Off", isOn: !isQuiet, DoNotDisturb())
                choice("For 1 hour", isOn: chosen == .oneHour, .untilOneHour(from: Date()))
                choice(
                    "Until tomorrow", isOn: chosen == .tomorrowMorning,
                    .untilTomorrowMorning(from: Date(), calendar: .current))
            } label: {
                Image(systemName: isQuiet ? Icons.doNotDisturb : Icons.bell)
            }
            .accessibilityLabel(Text(ui: "Do Not Disturb"))
            .accessibilityValue(quietValue)
            Button {
                app.startSearch()
            } label: {
                Image(systemName: Icons.search)
            }
            .accessibilityLabel(Text(ui: "Search"))
        } below: {
            // At the largest text sizes the picker and Filter go under each other rather than clip.
            ViewThatFits(in: .horizontal) {
                secondRow(HStack { picker; Spacer(minLength: 0); filter })
                secondRow(VStack(alignment: .leading, spacing: 10) { picker; filter })
            }
        }
    }

    private var isQuiet: Bool { app.doNotDisturbValue.isActive(at: Date()) }

    private var chosen: DoNotDisturb.Preset? { app.doNotDisturbValue.choice(at: Date()) }

    private var quietValue: Text {
        guard isQuiet, let until = app.doNotDisturbValue.until else { return Text(ui: "Off") }
        return Text(String(format: L10n.string("On until %@"), until.formatted(date: .abbreviated, time: .shortened)))
    }

    /// One of the bell's choices; the one in force carries a check mark.
    private func choice(_ title: LocalizedStringKey, isOn: Bool, _ value: DoNotDisturb) -> some View {
        Button {
            app.setDoNotDisturb(value)
        } label: {
            if isOn { Label(title, systemImage: Icons.confirm) } else { Text(title) }
        }
    }

    private func secondRow(_ content: some View) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var picker: some View {
        if inbox.showsFocusedOther {
            FocusedOtherPicker(selection: $inbox.inboxClass)
        }
    }

    private var filter: some View {
        FilterMenu(filter: $inbox.filter) { inbox.markAllRead() }
            .accessibilityIdentifier("inbox.filter")
    }
}

/// The account in view, or every account's mark when all are shown.
struct HeaderAvatar: View {
    let app: AppModel
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 34

    var body: some View {
        if let account = app.accountInView ?? (app.accounts.count == 1 ? app.accounts.first : nil) {
            Avatar(name: account.displayName, email: account.email, size: size, colorIndex: account.colorIndex)
                .overlay(Circle().stroke(Theme.header, lineWidth: 1.5))
        } else {
            Circle()
                .fill(Theme.headerTrack)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: Icons.allAccounts)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.headerText)
                }
        }
    }
}

/// Focused and Other as a capsule: the chosen side in the accent.
struct FocusedOtherPicker: View {
    @Binding var selection: InboxClass

    var body: some View {
        HStack(spacing: 0) {
            side(.focused, "Focused").accessibilityIdentifier("inbox.focused")
            side(.other, "Other").accessibilityIdentifier("inbox.other")
        }
        .padding(3)
        .background(Capsule().fill(Theme.headerTrack))
            }

    private func side(_ value: InboxClass, _ key: LocalizedStringKey) -> some View {
        Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(ui: key)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(selection == value ? Theme.onAccent : Theme.headerText)
                .background {
                    if selection == value {
                        Capsule().fill(Theme.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
