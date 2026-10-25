import SwiftUI
import WatchtowerCore
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
        /// The whole file, not the changes with unchanged runs folded.
        var fullFile = false
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
                "path": path, "original": original, "modified": modified, "inline": inline, "fullFile": fullFile,
                "comments": comments.map(\.argument), "notes": notes.map(\.argument), "hunks": hunks.map(\.argument)
            ]
        }
    }

    var payload: Payload?
    /// A line to put on screen once its file is shown (board #960); sent
    /// once per serial.
    var focus: ReviewChangesModel.FocusRequest?
    /// Go to definition and Usages from the new side (board #960): the
    /// pane's destination, through which the page's messages reach the
    /// centres and the menu's commands reach the page; nil = none.
    var navigation: ReviewNavigationDestination?
    /// The owner chose Comment on a selection: its lines and side ("old"/"new").
    var onComment: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    /// The owner chose Ask agent on a selection: its lines and side ("old"/"new").
    var onAsk: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void = { _, _, _ in }
    /// The owner pressed Undo on a hunk of the shown file (its id was checked).
    var onUndo: (_ hunkID: String) -> Void = { _ in }
    /// The page reported an error (also logged).
    var onError: (String) -> Void = { _ in }
    /// The focus request was sent to the page (the model clears it).
    var onFocusSent: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComment: onComment, onAsk: onAsk, onUndo: onUndo, onError: onError)
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
        context.coordinator.onAsk = onAsk
        context.coordinator.onUndo = onUndo
        context.coordinator.onError = onError
        context.coordinator.onFocusSent = onFocusSent
        context.coordinator.navigation = navigation
        // The preview may have held the menu's page: the diff is back.
        if navigation?.page !== context.coordinator { navigation?.page = context.coordinator }
        context.coordinator.show(payload, focus: focus)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, CodeDefinitionPage, CodeUsagesPage {
        weak var webView: WKWebView?
        weak var navigation: ReviewNavigationDestination?
        var onComment: (Int, Int, String) -> Void
        var onAsk: (Int, Int, String) -> Void
        var onUndo: (String) -> Void
        var onError: (String) -> Void
        var onFocusSent: (Int) -> Void = { _ in }
        private var ready = false
        /// What the page should show, and what it was last told.
        private var wanted: Payload?
        private var told: Payload?
        private var wantedFocus: ReviewChangesModel.FocusRequest?
        private var sentFocusSerial: Int?

        init(
            onComment: @escaping (Int, Int, String) -> Void,
            onAsk: @escaping (Int, Int, String) -> Void,
            onUndo: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onComment = onComment
            self.onAsk = onAsk
            self.onUndo = onUndo
            self.onError = onError
        }

        func show(_ payload: Payload?, focus: ReviewChangesModel.FocusRequest?) {
            wanted = payload
            wantedFocus = focus
            push()
            pushFocus()
        }

        /// `wt.focus(line)` once the page shows the request's file; the page
        /// holds it until the diff is computed (diff.js).
        private func pushFocus() {
            guard ready, let focus = wantedFocus, focus.serial != sentFocusSerial, told?.path == focus.path else { return }
            sentFocusSerial = focus.serial
            call("wt.focus", focus.line)
            // Not during the view update that carried it.
            let sent = onFocusSent
            Task { @MainActor in sent(focus.serial) }
        }

        /// Sends `wanted` once the page is ready and when it changed; only
        /// the comments, notes, hunks or Full file changed → their setters,
        /// the view keeps its scroll.
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
                same.fullFile = wanted.fullFile
                if same == wanted {
                    if previous.fullFile != wanted.fullFile { call("wt.setFullFile", wanted.fullFile) }
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
                pushFocus()
            case "comment":
                guard let start = body["startLine"] as? Int, let end = body["endLine"] as? Int,
                      let side = body["side"] as? String else {
                    NSLog("ReviewDiff: a comment message without its lines was dropped")
                    return
                }
                onComment(start, end, side)
            case "ask":
                guard let start = body["startLine"] as? Int, let end = body["endLine"] as? Int,
                      let side = body["side"] as? String else {
                    NSLog("ReviewDiff: an ask message without its lines was dropped")
                    return
                }
                onAsk(start, end, side)
            case "undo":
                guard let id = Self.undoTarget(body["hunkId"], shown: told?.hunks ?? []) else {
                    NSLog("ReviewDiff: an undo message for an unknown hunk was dropped")
                    return
                }
                onUndo(id)
            case "definition":
                Task { await definitionRequested(body) }
            case "usages":
                usagesRequested(body)
            case "error":
                report((body["message"] as? String) ?? "The diff view reported an error.")
            default:
                break
            }
        }

        // MARK: Code navigation (board #960)

        /// ⌘-click or the menu's Go to Definition: the centre in the
        /// session's root, then `definitionDone(req)` on every path.
        func definitionRequested(_ body: [String: Any]) async {
            guard let req = body["req"] as? Int else {
                NSLog("ReviewDiff: a definition message without req was dropped")
                return
            }
            defer { call("wt.definitionDone", req) }
            guard let origin = origin(body), let word = body["word"] as? String,
                  let navigation, let root = navigation.root, let definitions = navigation.definitions else { return }
            let request = CodeDefinitionRequest(req: req, word: word, origin: origin)
            await definitions.goToDefinition(request, root: root, anchor: menuAnchor(x: body["x"] as? Double, y: body["y"] as? Double))
        }

        /// Show All Usages: the list of the word in the session's root.
        func usagesRequested(_ body: [String: Any]) {
            guard origin(body) != nil, let word = body["word"] as? String,
                  let navigation, let root = navigation.root, let usages = navigation.usages else {
                NSLog("ReviewDiff: a usages message was dropped")
                return
            }
            usages.showUsages(of: word, root: root)
        }

        /// The root-relative place a message names; nil for a file other
        /// than the one shown or outside the workbench folder.
        private func origin(_ body: [String: Any]) -> CodeNavLocation? {
            guard let id = body["id"] as? String, let line = body["line"] as? Int, let col = body["col"] as? Int else { return nil }
            return navigation?.model?.diffNavigationOrigin(path: id, line: line, col: col)
        }

        /// The page's point (CSS px from the top left) in the web view.
        private func menuAnchor(x: Double?, y: Double?) -> DefinitionMenuAnchor? {
            guard let webView, let x, let y else { return nil }
            let flippedY = webView.isFlipped ? y : webView.bounds.height - y
            return DefinitionMenuAnchor(view: webView, point: NSPoint(x: x, y: flippedY))
        }

        func requestDefinitionAtCursor() async -> Bool {
            await ask("wt.definitionAtCursor()")
        }

        func requestUsagesAtCursor() async -> Bool {
            await ask("wt.usagesAtCursor()")
        }

        /// A page call answering true or false; false when the page cannot be asked.
        private func ask(_ script: String) async -> Bool {
            guard ready, let webView else { return false }
            do {
                return try await webView.evaluateJavaScript(script) as? Bool ?? false
            } catch {
                NSLog("ReviewDiff: %@ failed: %@", script, error.localizedDescription)
                return false
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
