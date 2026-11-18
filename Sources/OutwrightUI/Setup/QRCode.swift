// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code of a text (correction level M) with its quiet zone of four modules, one pixel a module, drawn
/// scaled up without smoothing so it stays sharp at any size. Nothing is drawn when the text does not fit in a
/// code.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    /// The modules of white around the code that a reader needs to find it.
    static let quietZone: CGFloat = 4
    private static let context = CIContext()

    /// The code's modules on white, quiet zone included, or nil when Core Image makes none.
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // Core Image's code comes with one module of margin of its own.
        let margin = quietZone - 1
        let extent = code.extent.insetBy(dx: -margin, dy: -margin)
        let white = CIImage(color: .white).cropped(to: extent)
        return context.createCGImage(code.composited(over: white), from: extent)
    }
}
