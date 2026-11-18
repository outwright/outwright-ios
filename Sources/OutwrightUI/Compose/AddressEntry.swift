// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(UIKit)
import UIKit

/// The field an address is typed in: a UIKit text field, which (unlike SwiftUI's) tells a backspace
/// in the empty field, so the chips before it can be selected and removed. It takes part in the
/// sheet's focus like the other fields: it takes the keyboard when `focus` is its `field`, and sets
/// `focus` when tapped.
struct AddressEntry<Field: Hashable>: UIViewRepresentable {
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    let field: Field
    let identifier: String
    let submit: () -> Void
    let emptyBackspace: () -> Void

    func makeUIView(context: Context) -> BackspaceField {
        let view = BackspaceField()
        view.delegate = context.coordinator
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.keyboardType = .emailAddress
        view.textContentType = .emailAddress
        view.returnKeyType = .next
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = UIColor(Theme.accent)
        view.accessibilityIdentifier = identifier
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return view
    }

    func updateUIView(_ view: BackspaceField, context: Context) {
        context.coordinator.parent = self
        view.emptyBackspace = emptyBackspace
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        let wanted = focus.wrappedValue == field
        // Only a change asks: the field is never pulled back while another has the keyboard.
        if wanted, !context.coordinator.wasWanted, !view.isFirstResponder {
            Task { @MainActor in view.becomeFirstResponder() }
        }
        context.coordinator.wasWanted = wanted
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressEntry
        var wasWanted = false

        init(parent: AddressEntry) {
            self.parent = parent
        }

        @objc func changed(_ view: UITextField) {
            parent.text = view.text ?? ""
            view.invalidateIntrinsicContentSize()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.focus.wrappedValue != parent.field {
                wasWanted = true
                parent.focus.wrappedValue = parent.field
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.submit()
            return false
        }
    }
}

/// A text field that says when backspace is pressed with nothing in it.
final class BackspaceField: UITextField {
    var emptyBackspace: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty { emptyBackspace?() }
        super.deleteBackward()
    }
}
#else
/// Where there is no UIKit: a plain field, without the backspace into the chips.
struct AddressEntry<Field: Hashable>: View {
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    let field: Field
    let identifier: String
    let submit: () -> Void
    let emptyBackspace: () -> Void

    var body: some View {
        TextField(text: $text) { EmptyView() }
            .emailEntry()
            .focused(focus, equals: field)
            .accessibilityIdentifier(identifier)
            .onSubmit(submit)
    }
}
#endif
