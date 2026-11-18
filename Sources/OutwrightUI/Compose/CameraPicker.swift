// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(UIKit)
import UIKit

/// The system camera, for a photo to attach: what it takes comes back as JPEG (quality 0.85).
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Whether this phone has a camera to offer (a simulator has none).
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(taken: taken, close: { dismiss() })
    }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let taken: (Data) -> Void
        let close: () -> Void

        init(taken: @escaping (Data) -> Void, close: @escaping () -> Void) {
            self.taken = taken
            self.close = close
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.85) {
                taken(jpeg)
            }
            close()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            close()
        }
    }
}
#else
/// No camera where there is no UIKit.
struct CameraPicker: View {
    let taken: (Data) -> Void

    static var isAvailable: Bool { false }

    var body: some View { EmptyView() }
}
#endif
