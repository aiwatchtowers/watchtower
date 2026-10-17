import AppKit
import CryptoKit
import SwiftUI
import WatchtowerCore
import WebKit

/// What the sandboxed HTML view shows (board #535).
enum SandboxedHTMLContent: Equatable {
    /// An in-memory page (a chat html artifact): no base URL, no file access.
    case page(String)
    /// A local html file; its css/js/images load from `folder` only.
    case file(URL, folder: URL)

    /// The folder a file preview may load from; nil for an in-memory page.
    var folder: URL? {
        if case let .file(_, folder) = self { return folder }
        return nil
    }
}

/// A WKWebView for HTML that may come from synced data through a prompt
/// injection: JavaScript on (decks need it), a non-persistent data store, no
/// script message handlers (no bridge to the app), network loads blocked by
/// a content rule list (`HTMLPreviewPolicy.contentRules`: none at all for a
/// chat artifact; a file preview gets its folder's visible files and the
/// CDN allowlist), WebRTC and DNS prefetch turned off in the web view's
/// preferences — every frame, a fresh iframe included (#563): content rules
/// cover neither — plus a document-start script removing the WebRTC globals
/// in every frame, every navigation away from
/// its own content cancelled — links open nothing — and a UI delegate that
/// opens no window, grants no camera or microphone and picks no file.
/// Nothing loads until the rule list is installed; if it cannot be compiled,
/// or WebRTC cannot be turned off, the page is never shown.
struct SandboxedHTMLView: NSViewRepresentable {
    let content: SandboxedHTMLContent
    /// Bump to load the content again (Reload, a file changed on disk).
    var reloadToken = 0
    /// Take keyboard focus after the first load, so the arrow keys reach the
    /// page (a deck's slides) without a click first.
    var focusOnLoad = false

    /// Runs before any page script, in every frame.
    static let removeWebRTC = """
    (() => { for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel"]) {
      try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
    } })();
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Turns WebRTC (and DNS prefetch, best effort) off for every frame of
    /// a web view made with `preferences`. These WebKit preferences have no
    /// public API (`_setPeerConnectionEnabled:`, `_setDNSPrefetchingEnabled:`);
    /// false when WebRTC could not be turned off, and the view then shows
    /// nothing (fail closed).
    static func lockDown(_ preferences: WKPreferences) -> Bool {
        _ = setPrivateFlag(preferences, "_setDNSPrefetchingEnabled:", false)
        return setPrivateFlag(preferences, "_setPeerConnectionEnabled:", false)
            && (preferences.value(forKey: "peerConnectionEnabled") as? Bool) == false
    }

    private static func setPrivateFlag(_ preferences: WKPreferences, _ name: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, value)
        return true
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let lockedDown = Self.lockDown(config.preferences)
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: Self.removeWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lockedDown = lockedDown
        context.coordinator.focusOnLoad = focusOnLoad
        context.coordinator.show(content, token: reloadToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(content, token: reloadToken)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var focusOnLoad = false
        /// WebRTC is off in the view's preferences (`lockDown`).
        var lockedDown = false
        private var shown: SandboxedHTMLContent?
        private var shownToken = 0
        private var focused = false
        private var load: Task<Void, Never>?
        /// The rule list in force. A different one is added before this one
        /// goes, so the view is never without a block.
        private var installed: WKContentRuleList?

        func show(_ content: SandboxedHTMLContent, token: Int) {
            if shown == content, shownToken == token { return }
            shown = content
            shownToken = token
            load?.cancel()
            load = Task { [weak self] in
                let rules = await SandboxedHTMLRules.list(folder: content.folder)
                guard let self, !Task.isCancelled, let webView = self.webView else { return }
                guard let rules, self.lockedDown else {
                    // Fail closed: without the network block, or with
                    // WebRTC still on, nothing is shown.
                    webView.loadHTMLString("<p style=\"font:13px -apple-system\">The preview could not be prepared.</p>", baseURL: nil)
                    return
                }
                self.install(rules, on: webView.configuration.userContentController)
                switch content {
                case let .page(html):
                    webView.loadHTMLString(html, baseURL: nil)
                case let .file(url, folder):
                    webView.loadFileURL(url, allowingReadAccessTo: folder)
                }
            }
        }

        private func install(_ rules: WKContentRuleList, on controller: WKUserContentController) {
            guard installed !== rules else { return }
            controller.add(rules)
            if let old = installed { controller.remove(old) }
            installed = rules
        }

        func cancel() { load?.cancel() }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            var page: URL?
            var folder: URL?
            if case let .file(url, root) = shown {
                page = url
                folder = root
            }
            let allowed = HTMLPreviewPolicy.allowsNavigation(
                to: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                page: page, folder: folder
            )
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard focusOnLoad, !focused, let window = webView.window else { return }
            focused = true
            window.makeFirstResponder(webView)
        }

        // MARK: WKUIDelegate — nothing leaves the view

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// The compiled content rule lists: one for in-memory pages and one per
/// previewed folder (its visible files, #563), each compiled once per launch
/// into a store in the temporary folder.
@MainActor
private enum SandboxedHTMLRules {
    private static var compiled: [String: WKContentRuleList] = [:]

    static func list(folder: URL?) async -> WKContentRuleList? {
        let rules = HTMLPreviewPolicy.contentRules(folder: folder)
        let key = SHA256.hash(data: Data(rules.utf8)).map { String(format: "%02x", $0) }.joined()
        if let list = compiled[key] { return list }
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("watchtower-html-preview-rules")
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: storeURL),
              let list = try? await store.compileContentRuleList(
                  forIdentifier: "watchtower.html-preview.v3.\(key)", encodedContentRuleList: rules
              ) else {
            return nil
        }
        compiled[key] = list
        return list
    }
}

/// A big window for an html page, optionally full screen at once (Present).
/// Esc leaves full screen when the page does not use it itself.
@MainActor
enum HTMLPreviewWindow {
    /// The open windows, each with its close observer, kept until closed.
    private static var windows: [(window: NSWindow, observer: NSObjectProtocol)] = []

    static func show(_ content: SandboxedHTMLContent, title: String, fullScreen: Bool) {
        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: SandboxedHTMLView(content: content, focusOnLoad: true))
        window.center()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let closing = note.object as? NSWindow
                for entry in windows where entry.window === closing {
                    NotificationCenter.default.removeObserver(entry.observer)
                }
                windows.removeAll { $0.window === closing }
            }
        }
        windows.append((window, observer))
        window.makeKeyAndOrderFront(nil)
        if fullScreen { window.toggleFullScreen(nil) }
    }

    private final class PreviewWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) {
            if styleMask.contains(.fullScreen) {
                toggleFullScreen(nil)
            } else {
                super.cancelOperation(sender)
            }
        }
    }
}
