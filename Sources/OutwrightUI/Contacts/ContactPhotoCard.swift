// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import PhotosUI
import SwiftUI

/// The contact's picture in the editor, chosen from the photo library; a new one is made small
/// (`ContactPhotos.prepared`) before it is kept.
struct ContactPhotoCard: View {
    @Bindable var model: ContactEditorModel
    @State private var picked: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 8) {
                // The label is read out here, on the main actor: the picker's label closure is Sendable.
                let title = model.photo == nil
                    ? String(localized: "Add photo", bundle: .module)
                    : String(localized: "Change photo", bundle: .module)
                PhotosPicker(selection: $picked, matching: .images) {
                    Text(verbatim: title)
                }
                if model.photo != nil, model.limits.removesPhoto {
                    Button(role: .destructive) { model.photo = nil } label: { Text(ui: "Remove photo") }
                }
            }
            .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let prepared = await Task.detached { data.flatMap { ContactPhotos.prepared($0) } }.value
                if let prepared { model.photo = prepared }
                picked = nil
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let data = model.photo, let image = ContactPhotos.thumbnail(data, pixels: 192) {
            Image(decorative: image, scale: 3)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
        } else {
            Avatar(
                name: model.details.name, email: model.details.emails.first?.value ?? model.details.name, size: 64)
        }
    }
}

/// Which part of a name a field holds, for AutoFill and capitals.
enum NameField {
    case givenName, familyName, organization, jobTitle
}

extension View {
    func nameEntry(_ kind: NameField) -> some View {
        #if os(iOS)
        let type: UITextContentType = switch kind {
        case .givenName: .givenName
        case .familyName: .familyName
        case .organization: .organizationName
        case .jobTitle: .jobTitle
        }
        return self.textContentType(type).textInputAutocapitalization(.words)
        #else
        return self
        #endif
    }
}
