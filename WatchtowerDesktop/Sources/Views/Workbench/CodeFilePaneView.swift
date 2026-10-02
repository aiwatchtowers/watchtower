import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore
import WebKit

/// POC (code viewer): a workspace pane showing one file of the workbench
/// folder in Monaco — a slim path bar (unsaved dot, Save), the conflict
/// banner when the disk moved under unsaved edits, then the editor.
struct CodeFilePaneView: View {
    let files: CodeFilesCenter
    let project: Workbench
    let relPath: String

    var body: some View {
        let buffer = files.buffer(for: project, relPath: relPath)
        VStack(spacing: 0) {
            pathBar(buffer)
            Divider()
            if buffer.conflict { conflictBanner(buffer) }
            if buffer.deletedOnDisk { notice("The file was deleted on disk. Save writes it back.", color: .orange) }
            if let error = buffer.saveError { notice("Could not save: \(error)", color: .red) }
            if let error = buffer.editorError { notice(error, color: .red) }
            switch buffer.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                MonacoEditorView(buffer: buffer, externalRevision: buffer.externalRevision, saveRequests: buffer.saveRequests)
            }
        }
        .task(id: relPath) { buffer.loadIfNeeded() }
    }

    private func pathBar(_ buffer: CodeFileBuffer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(relPath)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
                .help(buffer.url.path)
            if buffer.isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes — ⌘S saves")
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 4)
            Button("Save") { buffer.requestSave() }
                .disabled(!buffer.isDirty)
                .help("Save (⌘S in the editor)")
            Button {
                NSWorkspace.shared.open(buffer.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in the default app")
            .accessibilityLabel("Open in the default app")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func conflictBanner(_ buffer: CodeFileBuffer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("The file changed on disk while you had unsaved edits.").font(.caption)
            Spacer(minLength: 4)
            Button("Reload from disk") { buffer.reloadFromDisk() }
            Button("Keep mine") { buffer.keepMine() }
                .help("Keep your edits; the next save overwrites the file")
        }
        .controlSize(.small)
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// Monaco in a WKWebView, served from the bundled `CodeEditorWeb` folder
/// under wtcode://editor/ (a custom scheme rather than file://, so the
/// page has a real origin for its web workers). The page's protocol is
/// documented at the top of CodeEditorWeb/index.html.
struct MonacoEditorView: NSViewRepresentable {
    let buffer: CodeFileBuffer
    /// Read by the body so a reload from disk or a Save click re-runs
    /// `updateNSView`.
    let externalRevision: Int
    let saveRequests: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(buffer: buffer)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CodeEditorSchemeHandler.shared, forURLScheme: CodeEditorSchemeHandler.scheme)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "wt")
        let webView = WKWebView(frame: .zero, configuration: config)
        // No white flash before Monaco paints its (dark) background.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.revision = externalRevision
        context.coordinator.saveRequests = saveRequests
        webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pushReloadIfNeeded(revision: externalRevision)
        context.coordinator.requestSaveIfNeeded(saveRequests)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wt")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let buffer: CodeFileBuffer
        weak var webView: WKWebView?
        var revision = 0
        var saveRequests = 0
        private var ready = false

        init(buffer: CodeFileBuffer) {
            self.buffer = buffer
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                call("wt.open", ["path": "/" + buffer.relPath, "text": buffer.text, "dirty": buffer.isDirty])
            case "dirty":
                buffer.isDirty = body["dirty"] as? Bool ?? false
            case "text":
                if let text = body["text"] as? String { buffer.text = text }
            case "save":
                guard let text = body["text"] as? String else { return }
                if buffer.save(text) { call("wt.markSaved", nil) }
            case "error":
                buffer.editorError = body["message"] as? String
            default:
                break
            }
        }

        func pushReloadIfNeeded(revision newRevision: Int) {
            guard ready, newRevision != revision else { return }
            revision = newRevision
            call("wt.reload", buffer.text)
        }

        func requestSaveIfNeeded(_ requests: Int) {
            guard ready, requests != saveRequests else { return }
            saveRequests = requests
            call("wt.requestSave", nil)
        }

        /// `fn(arg)` with the argument JSON-encoded, so file text never
        /// needs escaping by hand.
        private func call(_ function: String, _ argument: Any?) {
            var literal = "null"
            if let argument,
               let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.fragmentsAllowed]),
               let array = String(data: data, encoding: .utf8) {
                literal = String(array.dropFirst().dropLast())
            }
            webView?.evaluateJavaScript("\(function)(\(literal))") { [weak self] _, error in
                if let error { self?.buffer.editorError = "Editor: \(error.localizedDescription)" }
            }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the
/// controller → coordinator → web view cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves the bundled `CodeEditorWeb` folder (index.html + the Monaco build
/// fetched by scripts/fetch-monaco.sh) to the editor's web views. Paths
/// that resolve outside the folder are refused.
final class CodeEditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "wtcode"
    static let shared = CodeEditorSchemeHandler()
    // swiftlint:disable:next force_unwrapping
    static let pageURL = URL(string: "\(scheme)://editor/index.html")!

    private let root: URL? = AppBundle.resources.url(forResource: "CodeEditorWeb", withExtension: nil)?.standardizedFileURL

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let root, let url = task.request.url else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let file = root.appendingPathComponent(String(url.path.drop { $0 == "/" })).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        )
        if let response { task.didReceive(response) }
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
