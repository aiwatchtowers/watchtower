import SwiftUI
import WatchtowerCore
import WebKit

/// A file outside the branch's diff, read-only in Branch review's centre
/// area (board #960, spec §2 "Where a jump lands"): the header names it and
/// leads back to the diff; the body is the code viewer's own page in
/// read-only mode, so ⌘-click and Usages walk the code from here too. The
/// file is read from the session's code root as it is now on disk.
struct ReviewCodePreview: View {
    let model: ReviewChangesModel
    let location: CodeNavLocation
    let root: CodeRoot
    /// Go to definition and Usages for the page's messages; nil = none.
    let navigation: CodeNavigationCenter?
    let usages: CodeUsagesCenter?

    @State private var text: Result<String, CodeFileBuffer.ReadError>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: LoadKey(path: location.path, folder: root.folder, serial: model.previewSerial)) {
            let url = root.folder.appendingPathComponent(location.path)
            let read = await Task.detached { CodeFileBuffer.read(url) }.value
            guard !Task.isCancelled else { return }
            text = read
        }
    }

    /// A new place re-reads the file: what is shown is the current files.
    private struct LoadKey: Equatable {
        let path: String
        let folder: URL
        let serial: Int
    }

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Text(location.path)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(location.path)
            Text("not changed in this branch · current files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.small)
            Button("← Back to diff") { model.closePreview() }
                .buttonStyle(.kitQuiet)
                .help("Back to the file of the diff")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    @ViewBuilder private var content: some View {
        switch text {
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failure(error):
            Text(error.message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .success(text):
            ReviewCodePreviewPage(
                file: ReviewCodePreviewPage.File(path: location.path, text: text),
                reveal: ReviewCodePreviewPage.Reveal(
                    path: location.path, line: location.line, col: location.col, serial: model.previewSerial
                ),
                root: root, navigation: navigation, usages: usages
            ) { model.previewCursorMoved($0) }
        }
    }
}

/// The code viewer's `index.html` page (`MonacoEditorView`'s) with one
/// read-only model: no buffer, no autosave, no Files tab. It speaks the
/// page's `definition`, `usages` and `cursor` messages; edits cannot be
/// typed, and a `text` message would be ignored.
struct ReviewCodePreviewPage: NSViewRepresentable {
    struct File: Equatable {
        let path: String
        let text: String
    }

    /// The place to put the cursor on; line 0 = none. Sent once per serial,
    /// once `path` is the file shown (the read of a new file may lag).
    struct Reveal: Equatable {
        let path: String
        let line: Int
        let col: Int
        let serial: Int
    }

    let file: File
    let reveal: Reveal
    let root: CodeRoot
    let navigation: CodeNavigationCenter?
    let usages: CodeUsagesCenter?
    let cursorMoved: (CodeNavLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        let coordinator = context.coordinator
        coordinator.root = root
        coordinator.navigation = navigation
        coordinator.usages = usages
        coordinator.cursorMoved = cursorMoved
        coordinator.show(file, reveal: reveal)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wt")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var root: CodeRoot?
        weak var navigation: CodeNavigationCenter?
        weak var usages: CodeUsagesCenter?
        var cursorMoved: (CodeNavLocation) -> Void = { _ in }
        private var ready = false
        private var wanted: File?
        private var wantedReveal: Reveal?
        /// What the page shows: the file and its model id (a new id per
        /// file shown, so a re-read text is never an old model's).
        private var shown: (file: File, id: String)?
        private var sentRevealSerial: Int?
        private var nextID = 0

        func show(_ file: File, reveal: Reveal) {
            wanted = file
            wantedReveal = reveal
            push()
        }

        private func push() {
            guard ready, let wanted else { return }
            if shown?.file != wanted {
                if let old = shown?.id { call("wt.close", old) }
                nextID += 1
                let id = "preview-\(nextID)"
                shown = (wanted, id)
                sentRevealSerial = nil
                call("wt.show", ["id": id, "path": wanted.path, "text": wanted.text, "rev": 0])
            }
            guard let reveal = wantedReveal, reveal.serial != sentRevealSerial, let shown, shown.file.path == reveal.path else {
                return
            }
            let id = shown.id
            sentRevealSerial = reveal.serial
            if reveal.line > 0 { call("wt.reveal", ["id": id, "line": reveal.line, "col": max(1, reveal.col)]) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                shown = nil
                call("wt.setReadOnly", true)
                push()
            case "definition":
                definitionRequested(body)
            case "usages":
                guard let word = body["word"] as? String, let root, let usages else {
                    NSLog("ReviewCodePreview: a usages message was dropped")
                    return
                }
                usages.showUsages(of: word, root: root)
            case "cursor":
                guard let path = shownPath(body), let line = body["line"] as? Int, let col = body["col"] as? Int else { return }
                cursorMoved(CodeNavLocation(path: path, line: line, col: col))
            case "error":
                NSLog("ReviewCodePreview: %@", (body["message"] as? String) ?? "the page reported an error")
            default:
                // text (never sent: read-only), selection, scroll, askAI: not here.
                break
            }
        }

        /// The path of the file a message names; nil for a model already gone.
        private func shownPath(_ body: [String: Any]) -> String? {
            guard let id = body["id"] as? String, let shown, shown.id == id else { return nil }
            return shown.file.path
        }

        /// ⌘-click: go to definition, then `definitionDone(req)` on every path.
        private func definitionRequested(_ body: [String: Any]) {
            guard let req = body["req"] as? Int else {
                NSLog("ReviewCodePreview: a definition message without req was dropped")
                return
            }
            guard let path = shownPath(body), let word = body["word"] as? String,
                  let line = body["line"] as? Int, let col = body["col"] as? Int,
                  let root, let navigation else {
                call("wt.definitionDone", req)
                return
            }
            let request = CodeDefinitionRequest(req: req, word: word, origin: CodeNavLocation(path: path, line: line, col: col))
            let anchor = menuAnchor(x: body["x"] as? Double, y: body["y"] as? Double)
            Task { @MainActor [weak self] in
                await navigation.goToDefinition(request, root: root, anchor: anchor)
                self?.call("wt.definitionDone", req)
            }
        }

        /// The page's point (CSS px from the top left) in the web view.
        private func menuAnchor(x: Double?, y: Double?) -> DefinitionMenuAnchor? {
            guard let webView, let x, let y else { return nil }
            let flippedY = webView.isFlipped ? y : webView.bounds.height - y
            return DefinitionMenuAnchor(view: webView, point: NSPoint(x: x, y: flippedY))
        }

        // MARK: WKNavigationDelegate

        /// The page may only ever be the bundled editor.
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
                NSLog("ReviewCodePreview: a navigation away from the editor page was cancelled")
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        /// The page's process died: reload it; `ready` shows the file again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            shown = nil
            webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        }

        private func call(_ function: String, _ argument: Any) {
            guard let script = MonacoEditorView.Coordinator.script(function, argument) else {
                NSLog("ReviewCodePreview: could not encode a call to %@", function)
                return
            }
            webView?.evaluateJavaScript(script) { _, error in
                if let error { NSLog("ReviewCodePreview: %@ failed: %@", function, error.localizedDescription) }
            }
        }
    }
}
