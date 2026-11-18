// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel
import SwiftUI

/// A small heading between the groups of rows in the server settings.
struct ServerGroup: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(ui: title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Host, port and encryption of one server.
struct EndpointRows: View {
    @Binding var endpoint: MailEndpoint?
    let defaultPort: UInt16
    /// The accessibility identifiers' middle part ("imap" or "smtp").
    let id: String

    var body: some View {
        Group {
            LabeledField("Server") {
                TextField(text: host) { Text(verbatim: "") }
                    .emailEntry()
                    .accessibilityIdentifier("addAccount.\(id).host")
            }
            LabeledField("Port") {
                TextField(text: port) { Text(verbatim: "") }
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("addAccount.\(id).port")
            }
            Picker(selection: security) {
                Text(ui: "TLS").tag("tls")
                Text(ui: "STARTTLS").tag("startTLS")
            } label: {
                Text(ui: "Encryption")
            }
            .accessibilityIdentifier("addAccount.\(id).security")
        }
    }

    private var current: MailEndpoint {
        endpoint ?? MailEndpoint(host: "", port: defaultPort, security: "tls")
    }

    private var host: Binding<String> {
        Binding { current.host } set: { value in
            var next = current
            next.host = value.trimmingCharacters(in: .whitespaces).lowercased()
            endpoint = next
        }
    }

    private var port: Binding<String> {
        Binding { String(current.port) } set: { value in
            var next = current
            next.port = UInt16(value.filter(\.isNumber).prefix(5)) ?? 0
            endpoint = next
        }
    }

    private var security: Binding<String> {
        Binding { current.security } set: { value in
            var next = current
            next.security = value
            endpoint = next
        }
    }
}

/// A row with its name before the field, so a filled-in field still says what it is (#59).
struct LabeledField<Field: View>: View {
    let label: LocalizedStringKey
    let field: Field

    init(_ label: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        LabeledContent {
            field
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(ui: label))
        } label: {
            Text(ui: label)
        }
    }
}
