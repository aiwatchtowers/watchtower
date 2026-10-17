import AppKit
import os
import SwiftUI
import WatchtowerCore
import WebKit

private let htmlPreviewLog = Logger(subsystem: Constants.bundleID, category: "html-preview")

/// What the sandboxed HTML view shows (board #535).
enum SandboxedHTMLContent: Equatable {
    /// An in-memory page (a chat html artifact): no base URL, no file access.
    case page(String)
    /// A local html file; its css/js/images load from `folder` only.
    case file(URL, folder: URL)

    var allowsFiles: Bool {
        if case .file = self { return true }
        return false
    }
}

/// A WKWebView for HTML that may come from synced data through a prompt
/// injection: JavaScript on (decks need it), a non-persistent data store, no
/// script message handlers (no bridge to the app), network loads blocked by
/// a content rule list (`HTMLPreviewPolicy.contentRules`: none at all for a
/// chat artifact; a file preview gets the CDN allowlist and its folder
/// through `SandboxedHTMLSchemeHandler`, which refuses hidden files and
/// symlinks into them, #563), WebRTC and DNS prefetch turned off in the
/// preferences (`lockDown`, every frame) plus a document-start script
/// removing the WebRTC globals in every frame, every navigation away from
/// its own content cancelled — links open nothing — and a UI delegate that
/// opens no window, grants no camera or microphone and picks no file.
/// Nothing loads until the rule list is installed; if it cannot be compiled
/// the page is never shown (the rules are the network barrier).
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

    /// The WebKit preferences (no public API) behind `lockDown`.
    struct LockDownSelectors {
        var setPeerConnection = "_setPeerConnectionEnabled:"
        var peerConnection = "_peerConnectionEnabled"
        var setDNSPrefetching = "_setDNSPrefetchingEnabled:"
    }

    /// Turns WebRTC (and DNS prefetch, best effort) off in `preferences`, so
    /// in every frame of a web view made with them, a fresh iframe included
    /// (#563). Nil when WebRTC is off, else why not (a WebKit without the
    /// selectors): the caller logs it and goes on with the document-start
    /// script, which removes the WebRTC globals in every frame too.
    static func lockDown(_ preferences: WKPreferences, selectors: LockDownSelectors = .init()) -> String? {
        _ = setFlag(preferences, selectors.setDNSPrefetching, false)
        guard setFlag(preferences, selectors.setPeerConnection, false) else {
            return "WKPreferences has no \(selectors.setPeerConnection)"
        }
        let getter = NSSelectorFromString(selectors.peerConnection)
        guard preferences.responds(to: getter) else { return "WKPreferences has no \(selectors.peerConnection)" }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let enabled = unsafeBitCast(preferences.method(for: getter), to: Getter.self)(preferences, getter)
        return enabled ? "\(selectors.peerConnection) still reads true" : nil
    }

    private static func setFlag(_ preferences: WKPreferences, _ name: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, value)
        return true
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let failure = Self.lockDown(config.preferences) {
            htmlPreviewLog.error("WebRTC stays on in the preferences (\(failure, privacy: .public)); the page script removes it")
        }
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: Self.removeWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: HTMLPreviewPolicy.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
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
        /// Serves a file preview's folder under `HTMLPreviewPolicy.scheme`.
        let files = SandboxedHTMLSchemeHandler()
        /// Where the rule list comes from (a test swaps in a failing one).
        var rules: @MainActor (_ allowFiles: Bool) async throws -> WKContentRuleList = { try await SandboxedHTMLRules.list(allowFiles: $0) }
        private var shown: SandboxedHTMLContent?
        private var shownToken = 0
        /// The preview URL of the file shown; nil for an in-memory page.
        private var page: URL?
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
                guard let self else { return }
                let rules: WKContentRuleList
                do {
                    rules = try await self.rules(content.allowsFiles)
                } catch {
                    guard !Task.isCancelled else { return }
                    // Fail closed: without the network block nothing is shown.
                    htmlPreviewLog.error("HTML preview rules did not compile: \(error.localizedDescription, privacy: .public)")
                    self.showMessage("The preview could not be prepared: \(error.localizedDescription)")
                    return
                }
                guard !Task.isCancelled, let webView = self.webView else { return }
                self.install(rules, on: webView.configuration.userContentController)
                switch content {
                case let .page(html):
                    self.page = nil
                    self.files.serve(nil)
                    webView.loadHTMLString(html, baseURL: nil)
                case let .file(url, folder):
                    let token = self.files.serve(folder)
                    self.page = HTMLPreviewPolicy.pageURL(file: url, folder: folder, token: token)
                    guard let page = self.page else {
                        return self.showMessage("The preview could not be prepared: the file is not in its folder.")
                    }
                    self.files.setPage(page)
                    webView.load(URLRequest(url: page))
                }
            }
        }

        /// A fixed message in place of the page; never the content.
        private func showMessage(_ text: String) {
            page = nil
            files.serve(nil)
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            webView?.loadHTMLString("<p style=\"font:13px -apple-system\">\(escaped)</p>", baseURL: nil)
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
            let allowed = HTMLPreviewPolicy.allowsNavigation(
                to: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true, page: page
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

/// The two compiled content rule lists (in-memory page, file preview), each
/// compiled once per launch — one compile in flight per mode — into WebKit's
/// default store. The first compile also drops the lists earlier versions
/// stored under other identifiers.
@MainActor
enum SandboxedHTMLRules {
    private static var compiled: [Bool: Task<WKContentRuleList, Error>] = [:]
    private static var cleaned = false
    private static let version = "v3"
    private static let stale = ["watchtower.html-preview.page.v2", "watchtower.html-preview.file.v2"]

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "WebKit's content rule store is unavailable." }
    }

    static func list(allowFiles: Bool) async throws -> WKContentRuleList {
        if let task = compiled[allowFiles] { return try await task.value }
        let task = Task { @MainActor () throws -> WKContentRuleList in
            guard let store = WKContentRuleListStore.default() else { throw Unavailable() }
            if !cleaned {
                cleaned = true
                for identifier in stale { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
            }
            let identifier = "watchtower.html-preview.\(allowFiles ? "file" : "page").\(version)"
            let rules = HTMLPreviewPolicy.contentRules(allowFiles: allowFiles)
            guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) else {
                throw Unavailable()
            }
            return list
        }
        compiled[allowFiles] = task
        do {
            return try await task.value
        } catch {
            compiled[allowFiles] = nil // a later view tries again
            throw error
        }
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
