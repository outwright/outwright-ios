// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#if os(iOS)
import OutwrightMIME
import SwiftUI
import UIKit
import WebKit

/// A message's HTML in the locked web view (`ReadingConfiguration`), as tall as its content.
/// Every navigation is cancelled; a tapped link is handed to `onLink`, which shows its address.
struct LockedWebView: UIViewRepresentable {
    let html: String
    let attachments: [Attachment]
    let allowRemote: Bool
    @Binding var height: CGFloat
    let onLink: (URL) -> Void
    /// The rule list couldn't be compiled: nothing was loaded, and the caller shows the text instead.
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onLink: onLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let handler = CIDSchemeHandler(attachments: attachments)
        let configuration = ReadingConfiguration.make(allowRemote: allowRemote, cidHandler: handler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.observe(webView)
        let page = ReadingConfiguration.page(html: html, allowRemote: allowRemote)
        let identifier = allowRemote ? "outwright.pictures.v2" : "outwright.locked.v2"
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: ReadingConfiguration.rules(allowRemote: allowRemote)
        ) { list, _ in
            // Fail closed: without the rule list nothing of the HTML is loaded.
            guard let list else {
                onUnavailable()
                return
            }
            // The web view holds a copy of the configuration it was made with: the list goes on
            // the one it uses.
            webView.configuration.userContentController.add(list)
            context.coordinator.allowsLoad = true
            webView.loadHTMLString(page, baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let height: Binding<CGFloat>
        let onLink: (URL) -> Void
        var allowsLoad = false
        private var observation: NSKeyValueObservation?

        init(height: Binding<CGFloat>, onLink: @escaping (URL) -> Void) {
            self.height = height
            self.onLink = onLink
        }

        func observe(_ webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let size = change.newValue else { return }
                Task { @MainActor in
                    let clamped = min(max(size.height, 20), 200_000)
                    if let self, abs(self.height.wrappedValue - clamped) > 1 {
                        self.height.wrappedValue = clamped
                    }
                }
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
        }

        /// Only our own page load runs; everything else is cancelled, and a link goes to the owner.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isOwnPage = url?.absoluteString == "about:blank" && navigationAction.navigationType == .other
                && navigationAction.targetFrame?.isMainFrame == true
            if isOwnPage, allowsLoad {
                allowsLoad = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url {
                onLink(url)
            }
        }

        /// A link meant for a new window is shown the same way, and no window opens.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { onLink(url) }
            return nil
        }
    }
}
#endif
