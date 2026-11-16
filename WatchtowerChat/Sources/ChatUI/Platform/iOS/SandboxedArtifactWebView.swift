#if os(iOS)
import os
import SwiftUI
import WebKit

/// The rules of the phone's html artifact view, the Mac's `HTMLPreviewPolicy` for a chat artifact: the page gets
/// JavaScript but no bridge to the app, no network of any scheme and no way to leave its own content. Pure.
public enum ArtifactHTMLPolicy {
    /// WebKit content rules: block every load, then let back in only what stays on the phone — `about:`, `data:`
    /// and `blob:`. (Content-rule regexes have no `|`, hence one rule per scheme.)
    static let contentRules: String = {
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let allow = ["^about:", "^data:", "^blob:"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }()

    static let rulesIdentifier = "watchtower.chat-artifact.page.v1"

    /// Navigation stays on the page: only `about:` (the in-memory page itself, and a fragment of it).
    static func allowsNavigation(to url: URL?) -> Bool {
        url?.scheme?.lowercased() == "about"
    }

    /// Runs before any page script, in every frame: no peer connections (they are not content-blocked loads).
    static let removeWebRTC = """
    (() => { for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel"]) {
      try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
    } })();
    """

    static let unavailable = "The page could not be shown: its sandbox could not be prepared."
}

/// An html artifact (mockup 3b, CHAT-05): a `WKWebView` with a non-persistent store, the content rules above
/// installed before anything loads (if they cannot be compiled the page is never shown), no script message
/// handlers, every navigation away from the page cancelled, no new windows, no camera or microphone.
public struct SandboxedArtifactWebView: UIViewRepresentable {
    let html: String

    public init(html: String) {
        self.html = html
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = Self.makeWebView(coordinator: context.coordinator)
        context.coordinator.show(html)
        return webView
    }

    /// The web view with the whole configuration, driven by `coordinator` (whose `show` loads a page once the rules
    /// are in); the tests build theirs here too.
    @MainActor
    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = false
        config.userContentController.addUserScript(
            WKUserScript(source: ArtifactHTMLPolicy.removeWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isOpaque = false
        coordinator.webView = webView
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(html)
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.load?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var load: Task<Void, Never>?
        private var shown: String?
        nonisolated private static let logger = Logger(subsystem: "WatchtowerChat", category: "ArtifactWebView")

        func show(_ html: String) {
            guard shown != html else { return }
            shown = html
            load?.cancel()
            load = Task { [weak self] in
                let rules: WKContentRuleList
                do {
                    rules = try await Self.rules()
                } catch {
                    Self.logger.error("artifact rules did not compile: \(String(describing: type(of: error)), privacy: .public)")
                    self?.webView?.loadHTMLString("<p style=\"font:15px -apple-system\">\(ArtifactHTMLPolicy.unavailable)</p>", baseURL: nil)
                    return
                }
                guard !Task.isCancelled, let webView = self?.webView else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(rules)
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        private static func rules() async throws -> WKContentRuleList {
            guard let store = WKContentRuleListStore.default(),
                  let list = try await store.compileContentRuleList(
                    forIdentifier: ArtifactHTMLPolicy.rulesIdentifier, encodedContentRuleList: ArtifactHTMLPolicy.contentRules
                  )
            else { throw RulesUnavailable() }
            return list
        }

        struct RulesUnavailable: Error {}

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(ArtifactHTMLPolicy.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        public func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }
    }
}
#endif
