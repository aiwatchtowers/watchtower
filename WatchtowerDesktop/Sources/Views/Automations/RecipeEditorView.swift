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
        // The host may hand this view another buffer in the same place (a
        // sheet for another automation, a rebuilt buffer): the coordinator
        // follows it rather than keep writing into the one it started with.
        context.coordinator.update(buffer: buffer, path: "\(slug).md", readOnly: readOnly)
    }

    /// The editor goes away: an edit the page has not sent yet (typed in the
    /// last 300 ms) reaches the buffer before the page is released.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private(set) var buffer: RecipeBufferModel
        private(set) var path: String
        weak var webView: WKWebView?
        private var readOnly: Bool
        private var state = RecipeEditorPageState()
        /// The buffer being let go after a rebind, while its model's unsent
        /// edits are pulled and the model is closed; nothing new is shown
        /// until then, and its late edits still reach it.
        private var retiring: (buffer: RecipeBufferModel, id: String, editable: Bool)?
        /// Bumped by each rebind and page restart: a stale rebind task stops.
        private var generation = 0

        init(buffer: RecipeBufferModel, readOnly: Bool, path: String) {
            self.buffer = buffer
            self.readOnly = readOnly
            self.path = path
            super.init()
            registerFlush(on: buffer)
        }

        /// A save awaits this buffer's `flush()`: it pulls the page's
        /// debounced edit into the buffer first.
        private func registerFlush(on buffer: RecipeBufferModel) {
            buffer.flushPending = { [weak self, weak buffer] in
                guard let self, let buffer, buffer === self.buffer else { return }
                await self.flush()
            }
        }

        /// Pulls an edit the page holds in its 300 ms debounce into the buffer.
        func flush() async {
            guard state.ready, !readOnly, retiring == nil, let webView else { return }
            let buffer = buffer
            let modelID = RecipeEditorPageState.modelID(buffer)
            guard let edits = await MonacoEditorView.Coordinator.takePending(from: webView) else { return }
            for edit in edits where edit.id == modelID {
                buffer.pageSent(text: edit.text, base: edit.base)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                state.pageReady()
                buffer.pageError = nil
                push()
            case "text":
                guard let id = body["id"] as? String, let text = body["text"] as? String,
                      let base = body["base"] as? Int else { return }
                guard let target = editTarget(for: id) else {
                    NSLog("RecipeEditor: an edit for another model or a read-only recipe was dropped")
                    return
                }
                target.pageSent(text: text, base: base)
            case "error":
                buffer.pageError = (body["message"] as? String) ?? "The editor reported an error."
            default:
                break
            }
        }

        private func editTarget(for id: String) -> RecipeBufferModel? {
            if let retiring {
                return retiring.id == id && retiring.editable ? retiring.buffer : nil
            }
            return id == RecipeEditorPageState.modelID(buffer) && !readOnly ? buffer : nil
        }

        func update(buffer newBuffer: RecipeBufferModel, path newPath: String, readOnly: Bool) {
            if RecipeEditorPageState.needsRebind(from: buffer, path: path, to: newBuffer, path: newPath) {
                rebind(to: newBuffer, path: newPath)
            }
            // An edit still in the page's 300 ms debounce when the same view
            // turns read-only is dropped; the form (editable) and the sheet
            // (read-only) are separate views, so this does not happen today.
            self.readOnly = readOnly
            push()
        }

        /// Lets the shown buffer go — its unsent edits pulled into it, its
        /// model closed — then shows the new one.
        private func rebind(to newBuffer: RecipeBufferModel, path newPath: String) {
            let old = retiring?.buffer ?? buffer
            let oldID = RecipeEditorPageState.modelID(old)
            let editable = retiring?.editable ?? !readOnly
            buffer = newBuffer
            path = newPath
            registerFlush(on: newBuffer)
            generation += 1
            guard state.ready, let webView else {
                retiring = nil
                state.rebound()
                return
            }
            retiring = (old, oldID, editable)
            let current = generation
            Task { @MainActor [weak self] in
                if editable, let edits = await MonacoEditorView.Coordinator.takePending(from: webView) {
                    for edit in edits where edit.id == oldID {
                        old.pageSent(text: edit.text, base: edit.base)
                    }
                }
                if let script = MonacoEditorView.Coordinator.script("wt.close", oldID) {
                    _ = try? await webView.evaluateJavaScript(script)
                }
                guard let self, self.generation == current else { return }
                self.retiring = nil
                self.state.rebound()
                self.push()
            }
        }

        private func push() {
            guard retiring == nil else { return }
            for command in state.commands(buffer: buffer, path: path, readOnly: readOnly) {
                switch command {
                case let .setReadOnly(flag):
                    call("wt.setReadOnly", flag)
                case let .show(id, path, text, rev):
                    call("wt.show", ["id": id, "path": path, "text": text, "rev": rev])
                case let .reload(id, text, rev):
                    call("wt.reload", ["id": id, "text": text, "rev": rev, "mode": "replace"])
                }
            }
        }

        func dismantle(_ webView: WKWebView) {
            let buffer = buffer
            let takeEdits = state.ready && !readOnly && retiring == nil
            let modelID = RecipeEditorPageState.modelID(buffer)
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
            state.pageLost()
            retiring = nil
            generation += 1
            webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        }

        /// `fn(<JSON argument>)`, so the recipe text never needs escaping by hand.
        private func call(_ function: String, _ argument: Any) {
            guard let script = MonacoEditorView.Coordinator.script(function, argument) else {
                buffer.pageError = "Editor: could not encode a call to \(function)."
                return
            }
            webView?.evaluateJavaScript(script) { [weak self] _, error in
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
