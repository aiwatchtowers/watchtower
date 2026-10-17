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
        /// The agent's placed notes on the new side.
        var notes: [Note] = []
        /// The file's hunks with their Undo state.
        var hunks: [Hunk] = []

        struct Note: Equatable {
            var startLine: Int
            var endLine: Int
            var text: String
        }

        struct Hunk: Equatable {
            var id: String
            var newStart: Int
            var canUndo: Bool
            /// Why Undo is off; the disabled button's title.
            var reason: String
        }

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
                "comments": comments.map(\.argument), "notes": notes.map(\.argument), "hunks": hunks.map(\.argument)
            ]
        }
    }

    var payload: Payload?
    /// The owner chose Comment on a selection: its lines and side ("old"/"new").
    var onComment: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    /// The owner pressed Undo on a hunk of the shown file (its id was checked).
    var onUndo: (_ hunkID: String) -> Void = { _ in }
    /// The page reported an error (also logged).
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComment: onComment, onUndo: onUndo, onError: onError)
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
        context.coordinator.onUndo = onUndo
        context.coordinator.onError = onError
        context.coordinator.show(payload)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onComment: (Int, Int, String) -> Void
        var onUndo: (String) -> Void
        var onError: (String) -> Void
        private var ready = false
        /// What the page should show, and what it was last told.
        private var wanted: Payload?
        private var told: Payload?

        init(
            onComment: @escaping (Int, Int, String) -> Void,
            onUndo: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onComment = onComment
            self.onUndo = onUndo
            self.onError = onError
        }

        func show(_ payload: Payload?) {
            wanted = payload
            push()
        }

        /// Sends `wanted` once the page is ready and when it changed; only
        /// the comments, notes or hunks changed → their setters, the view
        /// keeps its scroll.
        private func push() {
            guard ready, wanted != told else { return }
            defer { told = wanted }
            guard let wanted else {
                call("wt.showDiff", ["path": "", "original": "", "modified": "", "inline": false, "comments": []])
                return
            }
            if let previous = told {
                var same = previous
                same.comments = wanted.comments
                same.notes = wanted.notes
                same.hunks = wanted.hunks
                if same == wanted {
                    if previous.comments != wanted.comments { call("wt.setComments", wanted.comments.map(\.argument)) }
                    if previous.notes != wanted.notes { call("wt.setNotes", wanted.notes.map(\.argument)) }
                    if previous.hunks != wanted.hunks { call("wt.setHunks", wanted.hunks.map(\.argument)) }
                    return
                }
            }
            call("wt.showDiff", wanted.argument)
        }

        /// A hunk id is 16 lowercase hex digits (Go's `hunk_id`).
        nonisolated static func isHunkID(_ id: String) -> Bool {
            id.utf8.count == 16 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        }

        /// An Undo post counts only for a well-formed id of a hunk the page was told about.
        nonisolated static func undoTarget(_ id: Any?, shown: [Payload.Hunk]) -> String? {
            guard let id = id as? String, isHunkID(id), shown.contains(where: { $0.id == id && $0.canUndo }) else { return nil }
            return id
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
            case "undo":
                guard let id = Self.undoTarget(body["hunkId"], shown: told?.hunks ?? []) else {
                    NSLog("ReviewDiff: an undo message for an unknown hunk was dropped")
                    return
                }
                onUndo(id)
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

private extension MonacoDiffView.Payload.Note {
    var argument: [String: Any] { ["startLine": startLine, "endLine": endLine, "text": text] }
}

private extension MonacoDiffView.Payload.Hunk {
    var argument: [String: Any] { ["id": id, "newStart": newStart, "canUndo": canUndo, "reason": reason] }
}
