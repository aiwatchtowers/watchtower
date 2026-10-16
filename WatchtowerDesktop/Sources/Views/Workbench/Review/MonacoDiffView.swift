import SwiftUI
import WebKit

/// The Changes pane's read-only Monaco diff (board #328), served from the
/// bundled `CodeEditorWeb/diff.html` under wtcode://editor/ the way
/// `MonacoEditorView` serves the editor page; its protocol is documented at
/// the top of diff.html.
struct MonacoDiffView: NSViewRepresentable {
    struct Payload: Equatable {
        var path: String
        var original: String
        var modified: String
        var inline: Bool
        var comments: [Comment]

        struct Comment: Equatable, Encodable {
            var id: Int64
            var startLine: Int
            var endLine: Int
            var body: String
            var status: String
            var reply: String
        }

        /// The `wt.showDiff` argument, for JSONSerialization.
        var argument: [String: Any] {
            [
                "path": path, "original": original, "modified": modified, "inline": inline,
                "comments": comments.map(\.argument)
            ]
        }
    }

    var payload: Payload?
    /// The owner chose Comment on a selection: its lines and side ("old"/"new").
    var onComment: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    /// The page reported an error (also logged).
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComment: onComment, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CodeEditorSchemeHandler.shared, forURLScheme: CodeEditorSchemeHandler.scheme)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "wt")
        let webView = WKWebView(frame: .zero, configuration: config)
        // No white flash before Monaco paints its (dark) background.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: CodeEditorSchemeHandler.diffPageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onComment = onComment
        context.coordinator.onError = onError
        context.coordinator.show(payload)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onComment: (Int, Int, String) -> Void
        var onError: (String) -> Void
        private var ready = false
        /// What the page should show, and what it was last told.
        private var wanted: Payload?
        private var told: Payload?

        init(onComment: @escaping (Int, Int, String) -> Void, onError: @escaping (String) -> Void) {
            self.onComment = onComment
            self.onError = onError
        }

        func show(_ payload: Payload?) {
            wanted = payload
            push()
        }

        /// Sends `wanted` once the page is ready and when it changed; only
        /// the comments changed → `setComments`, the view keeps its scroll.
        private func push() {
            guard ready, wanted != told else { return }
            defer { told = wanted }
            guard let wanted else {
                call("wt.showDiff", ["path": "", "original": "", "modified": "", "inline": false, "comments": []])
                return
            }
            if var same = told {
                same.comments = wanted.comments
                if same == wanted {
                    call("wt.setComments", wanted.comments.map(\.argument))
                    return
                }
            }
            call("wt.showDiff", wanted.argument)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                told = nil
                push()
            case "comment":
                guard let start = body["startLine"] as? Int, let end = body["endLine"] as? Int,
                      let side = body["side"] as? String else {
                    NSLog("ReviewDiff: a comment message without its lines was dropped")
                    return
                }
                onComment(start, end, side)
            case "error":
                report((body["message"] as? String) ?? "The diff view reported an error.")
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        /// The page may only ever be the bundled diff page.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = CodeEditorSchemeHandler.allowsNavigation(
                to: navigationAction.request.url,
                mainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                page: CodeEditorSchemeHandler.diffPageURL
            )
            if !allowed {
                NSLog("ReviewDiff: a navigation away from the diff page was cancelled")
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report("The diff view could not load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report("The diff view could not load: \(error.localizedDescription)")
        }

        /// The page's process died: reload it; `ready` sends the diff again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            told = nil
            webView.load(URLRequest(url: CodeEditorSchemeHandler.diffPageURL))
        }

        private func report(_ message: String) {
            NSLog("ReviewDiff: %@", message)
            onError(message)
        }

        /// `fn(<JSON argument>)`, as `MonacoEditorView`'s `call` does.
        private func call(_ function: String, _ argument: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.fragmentsAllowed]),
                  let array = String(data: data, encoding: .utf8) else {
                report("Diff view: could not encode a call to \(function).")
                return
            }
            webView?.evaluateJavaScript("\(function)(\(array.dropFirst().dropLast()))") { [weak self] _, error in
                guard let error else { return }
                self?.report("Diff view: \(error.localizedDescription)")
            }
        }
    }
}

private extension MonacoDiffView.Payload.Comment {
    var argument: [String: Any] {
        ["id": id, "startLine": startLine, "endLine": endLine, "body": body, "status": status, "reply": reply]
    }
}
