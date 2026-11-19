// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit

@testable import OutwrightUI

/// A message that sets its own colours stays readable in dark mode: its colours are adapted, its
/// pictures are not, and the owner can show it as written.
@MainActor @Suite struct ReadingDarkModeTests {
    /// A light block, a dark block and a red picture, side by side.
    private static let html = """
        <div style="display:flex">
        <div style="background:#f0f0f0;color:#202020;width:60px;height:60px"></div>
        <div style="background:#202020;width:60px;height:60px"></div>
        <img width="60" height="60" src="data:image/png;base64,\(redPixel)">
        </div>
        """
    private static let redPixel =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    private struct Shown {
        let light: Double, dark: Double, picture: (red: Double, green: Double, blue: Double)
    }

    /// The page, laid out in the given appearance, sampled in the middle of each block.
    private func render(dark: Bool, adaptsColors: Bool) async throws -> Shown {
        let configuration = ReadingConfiguration.make(
            allowRemote: false, cidHandler: CIDSchemeHandler(attachments: []))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 120), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(
            ReadingConfiguration.page(html: Self.html, allowRemote: false, dark: dark, adaptsColors: adaptsColors), baseURL: nil)
        try await loaded.wait()
        let image = try await webView.takeSnapshot(configuration: nil)
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init))
        let scale = Double(bitmap.pixelsWide) / 300
        func sample(_ x: Double) throws -> NSColor {
            let color = try #require(bitmap.colorAt(x: Int(x * scale), y: Int(30 * scale)))
            return try #require(color.usingColorSpace(.sRGB))
        }
        let picture = try sample(16 + 120 + 30)
        return Shown(
            light: try sample(16 + 30).brightnessComponent, dark: try sample(16 + 60 + 30).brightnessComponent,
            picture: (picture.redComponent, picture.greenComponent, picture.blueComponent))
    }

    @Test func inDarkModeTheMessagesColoursAreTurnedAroundButNotItsPictures() async throws {
        let shown = try await render(dark: true, adaptsColors: true)
        #expect(shown.light < 0.3)
        #expect(shown.dark > 0.6)
        #expect(shown.picture.red > 0.8 && shown.picture.green < 0.25 && shown.picture.blue < 0.25)
    }

    @Test func inLightModeTheMessageIsShownAsWritten() async throws {
        let shown = try await render(dark: false, adaptsColors: true)
        #expect(shown.light > 0.7)
        #expect(shown.dark < 0.3)
    }

    @Test func theOwnerCanShowItAsWrittenInDarkMode() async throws {
        let shown = try await render(dark: true, adaptsColors: false)
        #expect(shown.light > 0.7)
        #expect(shown.dark < 0.3)
        #expect(shown.picture.red > 0.8 && shown.picture.green < 0.25)
    }
}

@MainActor private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var done = false

    func wait() async throws {
        if done { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        done = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
