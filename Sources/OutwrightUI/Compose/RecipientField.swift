// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import SwiftUI

/// A recipient line: its label, the people added as chips, and a field for the next one. A typed
/// address becomes a chip on return, a comma, a semicolon or a space.
struct RecipientField<Field: Hashable, Trailing: View>: View {
    let label: LocalizedStringKey
    @Binding var addresses: [Address]
    @Binding var typing: String
    var focus: FocusState<Field?>.Binding
    let field: Field
    /// Where the field's accessibility identifier starts: "compose.to", "editor.people".
    var identifierPrefix = "compose"
    /// Whether each recipient (by lower-case address) can receive protected mail; empty shows nothing.
    var keys: [String: RecipientKey] = [:]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(ui: label)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                        chip(address, index)
                    }
                    TextField(text: $typing) { EmptyView() }
                        .emailEntry()
                        .focused(focus, equals: field)
                        .accessibilityIdentifier("\(identifierPrefix).\(field)")
                        .submitLabel(.next)
                        .frame(minWidth: 120)
                        .onSubmit { commit() }
                        .onChange(of: typing) { _, text in
                            if let last = text.last, [",", ";", " "].contains(last) { commit() }
                        }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            trailing()
        }
        .font(.body)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
    }

    private func chip(_ address: Address, _ index: Int) -> some View {
        Menu {
            Text(address.email)
            Button(role: .destructive) {
                if addresses.indices.contains(index) { addresses.remove(at: index) }
            } label: {
                ModuleLabel("Remove", systemImage: "xmark")
            }
        } label: {
            HStack(spacing: 4) {
                if let symbol = Self.symbol(keyState(of: address)) {
                    Image(systemName: symbol)
                        .font(.caption)
                }
                Text(address.name ?? address.email)
                    .lineLimit(1)
            }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Theme.accent)
                .background(Theme.accentSoft, in: .capsule)
        }
    }

    private func keyState(of address: Address) -> RecipientKey? {
        keys[address.email.lowercased()] ?? (keys.isEmpty ? nil : RecipientKey.none)
    }

    private static func symbol(_ key: RecipientKey?) -> String? {
        switch key {
        case nil: nil
        case .some(.has): "lock.fill"
        case .some(.changed): "exclamationmark.triangle.fill"
        case .some(.looking): "ellipsis"
        case .some(.none): "lock.open"
        }
    }

    /// Every address typed or pasted becomes a chip; what isn't one stays in the field.
    private func commit() {
        let (found, rest) = RecipientParser.split(typing)
        guard !found.isEmpty else { return }
        addresses += found
        typing = rest.joined(separator: ", ")
    }
}

extension RecipientField where Trailing == EmptyView {
    init(
        label: LocalizedStringKey, addresses: Binding<[Address]>, typing: Binding<String>,
        focus: FocusState<Field?>.Binding, field: Field, identifierPrefix: String = "compose"
    ) {
        self.init(
            label: label, addresses: addresses, typing: typing, focus: focus, field: field,
            identifierPrefix: identifierPrefix
        ) { EmptyView() }
    }
}

extension View {
    /// The keyboard and corrections fit for typing an address.
    func emailEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
