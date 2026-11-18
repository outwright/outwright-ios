// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightMIME
import SwiftUI

/// A recipient line: its label, the people added as chips (wrapping onto more lines), and a field for
/// the next one. A typed address becomes a chip on return, a comma, a semicolon or a space. Backspace
/// in the empty field selects the last chip, and a second one removes it; Return in the empty field
/// moves on (`next`).
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
    /// Opens a recipient's key (by address) from their chip when it has changed; nil offers nothing.
    var showKey: ((String) -> Void)?
    /// Adds the people typed (leaving out those already on the message); nil appends them here.
    var add: (([Address]) -> Void)?
    /// Return in the empty field: the next field takes the keyboard; nil does nothing.
    var next: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    /// The chip backspace selected; a second backspace removes it.
    @State private var selected: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(ui: label)
                .foregroundStyle(Theme.secondaryText)
            FlowLayout {
                ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                    chip(address, index)
                }
                AddressEntry(
                    text: $typing, focus: focus, field: field, identifier: "\(identifierPrefix).\(field)",
                    submit: submit, emptyBackspace: backspace)
                    .focused(focus, equals: field)
                    .frame(minWidth: 120)
                    .onChange(of: typing) { _, text in
                        if !text.isEmpty { selected = nil }
                        if let last = text.last, [",", ";", " "].contains(last) { commit() }
                    }
            }
            .padding(.vertical, 10)
            trailing()
        }
        .font(.body)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
        .onChange(of: focus.wrappedValue) { _, now in if now != field { selected = nil } }
    }

    /// Return: what is typed becomes chips, or, with nothing typed, the next field takes the keyboard.
    private func submit() {
        if typing.trimmingCharacters(in: .whitespaces).isEmpty, let next {
            next()
        } else {
            commit()
        }
    }

    /// Backspace in the empty field: selects the last chip, or removes the chip selected.
    private func backspace() {
        if let index = selected {
            if addresses.indices.contains(index) { addresses.remove(at: index) }
            selected = nil
        } else if !addresses.isEmpty {
            selected = addresses.count - 1
        }
    }

    private func chip(_ address: Address, _ index: Int) -> some View {
        Menu {
            Text(address.email)
            if keyState(of: address) == .changed, let showKey {
                Button { showKey(address.email) } label: {
                    ModuleLabel("This person's key has changed", systemImage: Icons.warning)
                }
            }
            Button(role: .destructive) {
                if addresses.indices.contains(index) { addresses.remove(at: index) }
                selected = nil
            } label: {
                ModuleLabel("Remove", systemImage: Icons.close)
            }
        } label: {
            let isSelected = selected == index
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
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.accent)
                .background(isSelected ? Theme.accent : Theme.accentSoft, in: .capsule)
        }
        .accessibilityAddTraits(selected == index ? .isSelected : [])
    }

    private func keyState(of address: Address) -> RecipientKey? {
        keys[address.email.lowercased()] ?? (keys.isEmpty ? nil : RecipientKey.none)
    }

    private static func symbol(_ key: RecipientKey?) -> String? {
        switch key {
        case nil: nil
        case .some(.has): Icons.locked
        case .some(.changed): Icons.warningFilled
        case .some(.looking): Icons.more
        case .some(.none): Icons.unlocked
        }
    }

    /// Every address typed or pasted becomes a chip; what isn't one stays in the field.
    private func commit() {
        let (found, rest) = RecipientParser.split(typing)
        guard !found.isEmpty else { return }
        if let add {
            add(found)
        } else {
            addresses += found
        }
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
