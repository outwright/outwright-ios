// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(UIKit)
    @preconcurrency import AVFoundation
    import UIKit
#endif

/// The camera, reading QR codes: each text it reads goes to `found` (the same one once while it stays in
/// view). Without a camera, or without leave to use it, a message says so instead.
struct CodeScanner: View {
    let found: (String) -> Void

    #if canImport(UIKit)
        @State private var access: CameraAccess = .checking
        @Environment(\.openURL) private var openURL

        var body: some View {
            Group {
                switch access {
                case .checking:
                    Color.black
                case .allowed:
                    ScannerPreview(found: found) { access = .failed }
                case .failed:
                    ContentUnavailableView {
                        Label { Text(ui: "The camera couldn't be started") } icon: { Image(systemName: Icons.camera) }
                    } description: {
                        Text(ui: "Try again later, or send your setup as a file instead.")
                    }
                case .refused:
                    refused
                case .absent:
                    CodeScanner.noCamera
                }
            }
            .task { access = await CameraAccess.ask() }
        }

        private var refused: some View {
            ContentUnavailableView {
                Label { Text(ui: "Outwright can't use the camera") } icon: { Image(systemName: Icons.camera) }
            } description: {
                Text(ui: "Allow it in the Settings app, under Outwright, to scan the code.")
            } actions: {
                Button {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                } label: {
                    Text(ui: "Open Settings")
                }
                .accessibilityIdentifier("setup.openSettings")
            }
        }
    #else
        var body: some View { CodeScanner.noCamera }
    #endif

    static var noCamera: some View {
        ContentUnavailableView {
            Label { Text(ui: "No camera") } icon: { Image(systemName: Icons.camera) }
        } description: {
            Text(ui: "This device has no camera to scan the code with. Send your setup as a file instead.")
        }
    }
}

#if canImport(UIKit)
    /// Whether the camera can be used, asked for when it hasn't been yet.
    private enum CameraAccess {
        case checking, allowed, refused, absent
        /// There is a camera, but it could not be set up to read codes.
        case failed

        static func ask() async -> CameraAccess {
            guard AVCaptureDevice.default(for: .video) != nil else { return .absent }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .allowed
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .refused
            default: return .refused
            }
        }
    }

    /// The camera's picture, filling its frame, reading QR codes.
    private struct ScannerPreview: UIViewControllerRepresentable {
        let found: (String) -> Void
        let failed: () -> Void

        func makeUIViewController(context: Context) -> ScannerController {
            ScannerController(found: found, failed: failed)
        }

        func updateUIViewController(_ controller: ScannerController, context: Context) {
            controller.found = found
        }
    }

    /// Runs a capture session for as long as it is on screen; the session is set up, started and stopped on
    /// a queue of its own, as those calls block.
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: (String) -> Void
        private let failed: () -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.outwright.scanner")
        private var preview: AVCaptureVideoPreviewLayer?
        /// The last text read: one code held in view is reported once.
        private var last: String?

        init(found: @escaping (String) -> Void, failed: @escaping () -> Void) {
            self.found = found
            self.failed = failed
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            // The delegate is set here, on main, and the session queue holds the controller only weakly: it is
            // never freed there, only on the main thread, as UIKit requires.
            let output = AVCaptureMetadataOutput()
            output.setMetadataObjectsDelegate(self, queue: .main)
            let session = session
            queue.async { [weak self] in
                guard Self.configure(session, output: output) else {
                    Task { @MainActor [weak self] in self?.failed() }
                    return
                }
            }
        }

        /// Adds the camera and the QR code reader to the session; false when either can't be.
        private nonisolated static func configure(
            _ session: AVCaptureSession, output: AVCaptureMetadataOutput
        ) -> Bool {
            guard let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
            else { return false }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.addInput(input)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
            output.metadataObjectTypes = [.qr]
            return true
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            queue.async { if !session.isRunning { session.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            queue.async { if session.isRunning { session.stopRunning() } }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard let text = texts.first else { return }
            Task { @MainActor in self.read(text) }
        }

        private func read(_ text: String) {
            guard text != last else { return }
            last = text
            found(text)
        }
    }
#endif
