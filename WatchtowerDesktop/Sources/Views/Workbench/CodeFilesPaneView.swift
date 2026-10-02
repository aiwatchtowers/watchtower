import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore
import WebKit

/// POC (code viewer): the Files pane — the workbench's open file tabs over
/// one Monaco editor. A single click in the FILES tree opens a preview tab
/// (italic, replaced by the next single click); a double click, a double
/// click on the tab or the first edit keeps it. Edits save themselves.
struct CodeFilesPaneView: View {
    let files: CodeFilesCenter
    let project: Workbench
    @State private var discarding: String?

    var body: some View {
        let tabs = files.tabs(for: project)
        let git = files.git(for: project)
        VStack(spacing: 0) {
            if !tabs.tabs.isEmpty {
                CodeTabStrip(files: files, project: project, tabs: tabs, git: git) { discarding = $0 }
                Divider()
            }
            if let active = tabs.active {
                let buffer = files.buffer(for: project, relPath: active)
                CodeFileHeader(buffer: buffer, status: git.files[active])
                Divider()
                CodeFileBanners(buffer: buffer)
                switch buffer.state {
                case .loaded:
                    MonacoEditorView(files: files, project: project, tabs: tabs)
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: active) { buffer.loadIfNeeded() }
                case let .failed(message):
                    Text(message)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Open a file from FILES in the side panel")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "“\(discarding.map { ($0 as NSString).lastPathComponent } ?? "")” changed on disk while you were editing it",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close and Discard My Edits", role: .destructive) {
                if let path = discarding { files.discardAndClose(path, project: project) }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text("Your edits were not saved over the newer version. Cancel keeps the tab open with Reload / Keep mine.")
        }
    }
}

/// The tab strip: drag to reorder, double click keeps a preview tab.
private struct CodeTabStrip: View {
    let files: CodeFilesCenter
    let project: Workbench
    let tabs: CodeTabs
    let git: GitStatusSnapshot
    let onRefusedClose: (String) -> Void

    var body: some View {
        let subtitles = tabs.subtitles
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs.tabs, id: \.path) { tab in
                    CodeTabView(
                        tab: tab,
                        subtitle: subtitles[tab.path],
                        isActive: tabs.active == tab.path,
                        isDirty: files.buffer(for: project, relPath: tab.path).isDirty,
                        status: git.files[tab.path],
                        actions: actions(for: tab.path)
                    )
                    .draggable(tab.path)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first else { return false }
                        files.move(dragged, before: tab.path, project: project)
                        return true
                    }
                    Divider()
                }
            }
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func actions(for path: String) -> CodeTabView.Actions {
        CodeTabView.Actions(
            activate: { files.activate(path, project: project) },
            pin: { files.pin(path, project: project) },
            close: { close([path]) },
            closeOthers: { close(tabs.paths.filter { $0 != path }) },
            closeAll: { close(tabs.paths) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([project.folderURL.appendingPathComponent(path)]) },
            copyPath: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        )
    }

    private func close(_ paths: [String]) {
        if let refused = files.close(paths, project: project).first { onRefusedClose(refused) }
    }
}

private struct CodeTabView: View {
    struct Actions {
        let activate: () -> Void
        let pin: () -> Void
        let close: () -> Void
        let closeOthers: () -> Void
        let closeAll: () -> Void
        let reveal: () -> Void
        let copyPath: () -> Void
    }

    let tab: CodeTabs.Tab
    let subtitle: String?
    let isActive: Bool
    let isDirty: Bool
    let status: GitFileStatus?
    let actions: Actions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text((tab.path as NSString).lastPathComponent)
                .italic(tab.isPreview)
                .foregroundStyle(status.map(GitMark.color) ?? (isActive ? Color.primary : Color.secondary))
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            if let status {
                Text(status.letter).font(.caption2.monospaced()).foregroundStyle(GitMark.color(status))
            }
            closeOrDirty
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: actions.pin)
        .simultaneousGesture(TapGesture().onEnded(actions.activate))
        .onHover { isHovering = $0 }
        .help(tab.path)
        .contextMenu {
            Button("Close", action: actions.close)
            Button("Close Others", action: actions.closeOthers)
            Button("Close All", action: actions.closeAll)
            Divider()
            if tab.isPreview { Button("Keep Open", action: actions.pin) }
            Button("Reveal in Finder", action: actions.reveal)
            Button("Copy Relative Path", action: actions.copyPath)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close") { actions.close() }
    }

    /// × on hover or on the active tab; otherwise the not-yet-saved dot.
    @ViewBuilder
    private var closeOrDirty: some View {
        if isHovering || (isActive && !isDirty) {
            Button(action: actions.close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close \((tab.path as NSString).lastPathComponent)")
        } else if isDirty {
            Circle().fill(Color.secondary).frame(width: 7, height: 7).help("Not saved yet")
        } else {
            Color.clear.frame(width: 9, height: 9)
        }
    }
}

/// Colors of the git marks, shared by the tree and the tabs.
enum GitMark {
    static func color(_ status: GitFileStatus) -> Color {
        switch status {
        case .modified, .renamed: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        }
    }
}

/// The active file's path, its git mark and whether it is on disk yet.
private struct CodeFileHeader: View {
    let buffer: CodeFileBuffer
    let status: GitFileStatus?

    var body: some View {
        HStack(spacing: 6) {
            Text(buffer.relPath)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
                .help(buffer.url.path)
            Spacer(minLength: 4)
            if let status {
                Text(status.letter)
                    .font(.caption.monospaced())
                    .foregroundStyle(GitMark.color(status))
                    .help("Not committed")
            }
            Text(buffer.isDirty ? "Edited" : "Saved")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(buffer.isDirty ? "Saves itself a second after you stop typing" : "On disk")
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
}

private struct CodeFileBanners: View {
    let buffer: CodeFileBuffer

    var body: some View {
        if buffer.conflict {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The file changed on disk while you were editing. Your edits are not saved.").font(.caption)
                Spacer(minLength: 4)
                Button("Reload from disk") { buffer.reloadFromDisk() }
                Button("Keep mine") { buffer.keepMine() }
                    .help("Write your edits over the newer version")
            }
            .controlSize(.small)
            .padding(8)
            .background(Color.orange.opacity(0.12))
        }
        if buffer.deletedOnDisk { notice("The file was deleted on disk. Your next edit writes it back.", color: .orange) }
        if let error = buffer.saveError { notice("Could not save: \(error)", color: .red) }
        if let error = buffer.editorError { notice(error, color: .red) }
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

/// One Monaco for the whole pane, served from the bundled `CodeEditorWeb`
/// folder under wtcode://editor/ (a custom scheme rather than file://, so
/// the page has a real origin for its web workers). Switching tabs switches
/// models inside the page; its protocol is documented at the top of
/// CodeEditorWeb/index.html.
struct MonacoEditorView: NSViewRepresentable {
    let files: CodeFilesCenter
    let project: Workbench
    let tabs: CodeTabs

    func makeCoordinator() -> Coordinator {
        Coordinator(files: files, project: project)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CodeEditorSchemeHandler.shared, forURLScheme: CodeEditorSchemeHandler.scheme)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "wt")
        let webView = WKWebView(frame: .zero, configuration: config)
        // No white flash before Monaco paints its (dark) background.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Read here so a disk reload re-runs this (observation).
        let revisions = Dictionary(uniqueKeysWithValues: tabs.paths.map { path in
            (path, files.buffer(for: project, relPath: path).externalRevision)
        })
        context.coordinator.sync(tabs: tabs, revisions: revisions)
    }

    /// The pane goes away: what the page has not sent yet is pulled and saved.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.flushOnDismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let files: CodeFilesCenter
        let project: Workbench
        weak var webView: WKWebView?
        private var ready = false
        private var shown: String?
        private var revisions: [String: Int] = [:]
        private var tabs = CodeTabs()

        init(files: CodeFilesCenter, project: Workbench) {
            self.files = files
            self.project = project
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                shown = nil
                sync(tabs: tabs, revisions: revisions)
            case "text":
                guard let path = body["path"] as? String, let text = body["text"] as? String,
                      let buffer = files.existingBuffer(project, path) else { return }
                buffer.edited(text, now: body["now"] as? Bool ?? false)
                // The first edit keeps a preview tab.
                if buffer.isDirty, tabs.tabs.first(where: { $0.path == path })?.isPreview == true {
                    files.pin(path, project: project)
                }
            case "error":
                if let active = tabs.active {
                    files.buffer(for: project, relPath: active).editorError = body["message"] as? String
                }
            default:
                break
            }
        }

        func sync(tabs newTabs: CodeTabs, revisions newRevisions: [String: Int]) {
            let closed = tabs.paths.filter { !newTabs.contains($0) }
            tabs = newTabs
            guard ready else {
                revisions = newRevisions
                return
            }
            for path in closed { call("wt.close", path) }
            for (path, revision) in newRevisions where revisions[path].map({ $0 != revision }) == true {
                call("wt.reload", path, files.buffer(for: project, relPath: path).text)
            }
            revisions = newRevisions
            if let active = newTabs.active, active != shown {
                let buffer = files.buffer(for: project, relPath: active)
                buffer.loadIfNeeded()
                guard buffer.state == .loaded else { return }
                shown = active
                call("wt.show", ["path": active, "text": buffer.text])
            }
        }

        func flushOnDismantle(_ webView: WKWebView) {
            // The handler is still attached: the page's flush posts its
            // pending edits through it before the view is released.
            webView.evaluateJavaScript("wt.flush()") { _, _ in
                withExtendedLifetime(webView) {
                    webView.configuration.userContentController.removeScriptMessageHandler(forName: "wt")
                }
            }
        }

        /// `fn(args…)` with every argument JSON-encoded, so file text never
        /// needs escaping by hand.
        private func call(_ function: String, _ arguments: Any...) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]),
                  let array = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("\(function)(\(array.dropFirst().dropLast()))") { [weak self] _, error in
                guard let self, let error, let active = self.tabs.active else { return }
                self.files.buffer(for: self.project, relPath: active).editorError = "Editor: \(error.localizedDescription)"
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
