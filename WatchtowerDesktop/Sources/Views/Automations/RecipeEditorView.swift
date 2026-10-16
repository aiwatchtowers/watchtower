import AppKit
import SwiftUI
import WatchtowerCore
import WebKit

/// The whole recipe file (frontmatter, description, script) in the bundled
/// Monaco page (`CodeEditorWeb/`, the Files pane's page) — R-P3-10. One page,
/// one model `automation-<id>` named `<slug>.md`, so the file highlights as
/// Markdown and the script keeps its fence. Editable in the edit form,
/// read-only in the confirmation sheet (`setReadOnly`). It reads and writes
/// only `buffer`: no `CodeFilesCenter`, no disk.
struct RecipeEditorView: NSViewRepresentable {
    let buffer: RecipeBufferModel
    let readOnly: Bool
    /// The recipe's slug; only the model's name (and so its language) uses it.
    let slug: String

    init(buffer: RecipeBufferModel, readOnly: Bool, slug: String = "recipe") {
        self.buffer = buffer
        self.readOnly = readOnly
        self.slug = slug
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(buffer: buffer, readOnly: readOnly, path: "\(slug).md")
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
        webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Read here so a `reset` re-runs this (observation), even before the
        // page is ready.
        _ = buffer.revision
        context.coordinator.sync(readOnly: readOnly)
    }

    /// The editor goes away: an edit the page has not sent yet (typed in the
    /// last 300 ms) reaches the buffer before the page is released.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let buffer: RecipeBufferModel
        let path: String
        weak var webView: WKWebView?
        private var readOnly: Bool
        private var ready = false
        /// What the page was last told; a fresh page is editable.
        private var toldRevision: Int?
        private var toldReadOnly = false

        private var modelID: String { "automation-\(buffer.automationID)" }

        init(buffer: RecipeBufferModel, readOnly: Bool, path: String) {
            self.buffer = buffer
            self.readOnly = readOnly
            self.path = path
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                toldRevision = nil
                toldReadOnly = false
                buffer.pageError = nil
                push()
            case "text":
                guard let id = body["id"] as? String, let text = body["text"] as? String,
                      let base = body["base"] as? Int else { return }
                guard id == modelID, !readOnly else {
                    NSLog("RecipeEditor: an edit for another model or a read-only recipe was dropped")
                    return
                }
                buffer.pageSent(text: text, base: base)
            case "error":
                buffer.pageError = (body["message"] as? String) ?? "The editor reported an error."
            default:
                break
            }
        }

        func sync(readOnly: Bool) {
            self.readOnly = readOnly
            push()
        }

        /// Tells the page what changed since it was last told: read-only
        /// first (so `show` leaves the keyboard alone in a sheet), then the
        /// text — `show` the first time, `reload` (replace: an unsent edit is
        /// sent on its old base and kept) after a `reset`.
        private func push() {
            guard ready else { return }
            if toldReadOnly != readOnly {
                call("wt.setReadOnly", readOnly)
                toldReadOnly = readOnly
            }
            guard toldRevision != buffer.revision else { return }
            if toldRevision == nil {
                call("wt.show", ["id": modelID, "path": path, "text": buffer.text, "rev": buffer.revision])
            } else {
                call("wt.reload", ["id": modelID, "text": buffer.text, "rev": buffer.revision, "mode": "replace"])
            }
            toldRevision = buffer.revision
        }

        func dismantle(_ webView: WKWebView) {
            let buffer = buffer
            let takeEdits = ready && !readOnly
            let modelID = modelID
            Task { @MainActor in
                // `webView` and `buffer` are held by this task, not by the
                // coordinator SwiftUI is releasing.
                if takeEdits, let edits = await MonacoEditorView.Coordinator.takePending(from: webView) {
                    for edit in edits where edit.id == modelID {
                        buffer.pageSent(text: edit.text, base: edit.base)
                    }
                }
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "wt")
            }
        }

        // MARK: WKNavigationDelegate

        /// The page may only ever be the bundled editor (see the Files pane's
        /// MonacoEditorView): anything else could post `text`.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = CodeEditorSchemeHandler.allowsNavigation(
                to: navigationAction.request.url,
                mainFrame: navigationAction.targetFrame?.isMainFrame ?? false
            )
            if !allowed {
                NSLog("RecipeEditor: a navigation away from the editor page was cancelled")
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            buffer.pageError = "The editor could not load: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            buffer.pageError = "The editor could not load: \(error.localizedDescription)"
        }

        /// The page's process died: edits it had not sent are gone; reload.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            buffer.pageError = "The editor stopped and was restarted. Edits typed in the last moment may be lost."
            ready = false
            toldRevision = nil
            toldReadOnly = false
            webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        }

        /// `fn(<JSON argument>)`, so the recipe text never needs escaping by hand.
        private func call(_ function: String, _ argument: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.fragmentsAllowed]),
                  let array = String(data: data, encoding: .utf8) else {
                buffer.pageError = "Editor: could not encode a call to \(function)."
                return
            }
            webView?.evaluateJavaScript("\(function)(\(array.dropFirst().dropLast()))") { [weak self] _, error in
                guard let self, let error else { return }
                self.buffer.pageError = "Editor: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    RecipeEditorView(
        buffer: RecipeBufferModel(
            automationID: 1,
            text: "---\nname: Digest\ntrigger: manual\n---\n\nSummarises the week.\n\n```js\nlog(\"hello\")\n```\n",
            contentHash: "preview"
        ),
        readOnly: true,
        slug: "digest"
    )
    .frame(width: 560, height: 320)
}
