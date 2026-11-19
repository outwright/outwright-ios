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
    /// The app is in dark mode: the page's colours are turned for it unless `adaptsColors` is off.
    let dark: Bool
    let adaptsColors: Bool
    @Binding var height: CGFloat
    let onLink: (URL) -> Void
    /// The rule list couldn't be compiled: nothing was loaded, and the caller shows the text instead.
    let onUnavailable: () -> Void
    /// The page has loaded and been laid out.
    var onShown: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onLink: onLink, onShown: onShown, onUnavailable: onUnavailable)
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
        let page = ReadingConfiguration.page(
            html: html, allowRemote: allowRemote, dark: dark, adaptsColors: adaptsColors)
        context.coordinator.page = page
        ReadingRuleLists.list(allowRemote: allowRemote) { list in
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
        let onShown: () -> Void
        /// The page can't be shown: the caller shows the plain text instead.
        let onUnavailable: () -> Void
        var allowsLoad = false
        /// Our own page, kept to load it again once after its process ended.
        var page = ""
        /// The body has been shown: from then on only a second process end gives it up.
        private var shown = false
        private var reloaded = false
        private var observation: NSKeyValueObservation?

        init(
            height: Binding<CGFloat>, onLink: @escaping (URL) -> Void, onShown: @escaping () -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.height = height
            self.onLink = onLink
            self.onShown = onShown
            self.onUnavailable = onUnavailable
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

        /// The page is laid out (nothing is drawn before it is whole): the body takes its place.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            shown = true
            onShown()
        }

        /// Shown as far as it got, rather than a spinner for ever.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            shown = true
            onShown()
        }

        /// Our own page never started: the plain text stands in, rather than a spinner for ever. A
        /// navigation cancelled here (a link, a redirect, a frame) fails too, and changes nothing.
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
        ) {
            let error = error as NSError
            if ReadingFailure.needsText(domain: error.domain, code: error.code, shown: shown) {
                onUnavailable()
            }
        }

        /// The page's process ended (hostile HTML can bring it down): before it showed, the plain text
        /// stands in; a body already read loads again once.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            switch ReadingFailure.afterTermination(shown: shown, reloaded: reloaded) {
            case .showText:
                onUnavailable()
            case .reload:
                reloaded = true
                allowsLoad = true
                webView.loadHTMLString(page, baseURL: nil)
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

/// The rule lists, compiled once and kept: compiling one took up to two seconds, on every message
/// opened. A stored list is found by the hash of its rules, so a changed rule is never answered by an
/// older list.
@MainActor
enum ReadingRuleLists {
    private static var lists: [Bool: WKContentRuleList] = [:]
    private static var waiting: [Bool: [(WKContentRuleList?) -> Void]] = [:]
    /// An empty locked page that keeps WebKit's processes running, so a message's body doesn't wait
    /// for them to start (seconds on a phone that has just started the app).
    private static var warm: WKWebView?
    /// Lists stored under identifiers of earlier rules were removed this run.
    private static var tidied = false

    static func list(allowRemote: Bool, _ done: @escaping (WKContentRuleList?) -> Void) {
        if let list = lists[allowRemote] {
            done(list)
            return
        }
        if waiting[allowRemote] != nil {
            waiting[allowRemote]?.append(done)
            return
        }
        waiting[allowRemote] = [done]
        let rules = ReadingConfiguration.rules(allowRemote: allowRemote)
        let name = identifier(allowRemote: allowRemote)
        guard let store = WKContentRuleListStore.default() else {
            finish(allowRemote, nil)
            return
        }
        store.lookUpContentRuleList(forIdentifier: name) { found, _ in
            if let found {
                finish(allowRemote, found)
                return
            }
            store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: rules) { list, _ in
                finish(allowRemote, list)
            }
        }
    }

    private static func identifier(allowRemote: Bool) -> String {
        "outwright.reading." + ReadingConfiguration.fingerprint(ReadingConfiguration.rules(allowRemote: allowRemote))
    }

    private static func finish(_ allowRemote: Bool, _ list: WKContentRuleList?) {
        if let list { lists[allowRemote] = list }
        let callers = waiting[allowRemote] ?? []
        waiting[allowRemote] = nil
        for caller in callers { caller(list) }
        if lists.count == 2 { removeEarlierLists() }
    }

    /// Once a run, with the current lists ready: every list of ours stored under another identifier
    /// (earlier rules, earlier names) is removed, so old compiled rules don't pile up.
    private static func removeEarlierLists() {
        guard !tidied, let store = WKContentRuleListStore.default() else { return }
        tidied = true
        let current: Set<String> = [identifier(allowRemote: false), identifier(allowRemote: true)]
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for old in identifiers ?? [] where old.hasPrefix("outwright.") && !current.contains(old) {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    /// Readies what a message's body needs before one is opened: both rule lists, and WebKit's processes,
    /// started by an empty locked page that loads nothing.
    static func warmUp() {
        list(allowRemote: true) { _ in }
        list(allowRemote: false) { list in
            guard let list, warm == nil else { return }
            let configuration = ReadingConfiguration.make(
                allowRemote: false, cidHandler: CIDSchemeHandler(attachments: []))
            configuration.userContentController.add(list)
            let webView = WKWebView(frame: .zero, configuration: configuration)
            warm = webView
            webView.loadHTMLString(ReadingConfiguration.page(html: "", allowRemote: false), baseURL: nil)
        }
    }
}
#endif
