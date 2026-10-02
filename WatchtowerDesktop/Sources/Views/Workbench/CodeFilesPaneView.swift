import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore
import WebKit

/// The Files pane — the workbench's open file tabs over one Monaco editor.
/// A single click in the FILES tree opens a preview tab (italic, replaced by
/// the next single click); a double click, a double click on the tab or the
/// first edit keeps it. Edits save themselves (`CodeFileBuffer`). The editor
/// stays mounted while tabs are open, so every tab keeps its undo, cursor
/// and scroll; loading and errors show over it.
struct CodeFilesPaneView: View {
    let files: CodeFilesCenter
    let project: Workbench
    @State private var refusals: [CodeFilesCenter.Refusal] = []

    var body: some View {
        let tabs = files.tabs(for: project)
        let git = files.git(for: project)
        VStack(spacing: 0) {
            if let error = files.editorErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            if tabs.tabs.isEmpty {
                Text("Open a file from FILES in the side panel")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTabStrip(files: files, project: project, tabs: tabs, git: git) { refusals = $0 }
                Divider()
                if let active = tabs.active {
                    let buffer = files.buffer(for: project, relPath: active)
                    CodeFileHeader(buffer: buffer, status: git.files[active])
                    Divider()
                    CodeFileBanners(buffer: buffer)
                }
                MonacoEditorView(files: files, project: project, tabs: tabs)
                    .overlay { activeOverlay(tabs) }
            }
        }
        .task(id: project.id) { await files.show(project) }
        .task(id: tabs.active) {
            if let active = tabs.active { files.buffer(for: project, relPath: active).loadIfNeeded() }
        }
        .confirmationDialog(
            refusals.count == 1 ? "“\(Self.name(refusals[0].path))” has edits that could not be saved"
                : "\(refusals.count) tabs have edits that could not be saved",
            isPresented: Binding(get: { !refusals.isEmpty }, set: { if !$0 { refusals = [] } }),
            titleVisibility: .visible
        ) {
            Button("Close and Discard Edits", role: .destructive) {
                files.discardAndClose(refusals.map(\.path), project: project)
                refusals = []
            }
            Button("Cancel", role: .cancel) { refusals = [] }
        } message: {
            Text(refusals.map { "\(Self.name($0.path)): \($0.reason)" }.joined(separator: "\n"))
        }
    }

    /// Over the editor while the active file is not on it.
    @ViewBuilder
    private func activeOverlay(_ tabs: CodeTabs) -> some View {
        if let active = tabs.active {
            switch files.buffer(for: project, relPath: active).state {
            case .loaded:
                EmptyView()
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// The tab strip: drag to reorder, double click keeps a preview tab.
private struct CodeTabStrip: View {
    let files: CodeFilesCenter
    let project: Workbench
    let tabs: CodeTabs
    let git: GitStatusSnapshot
    let onRefused: ([CodeFilesCenter.Refusal]) -> Void

    var body: some View {
        let subtitles = tabs.subtitles
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs.tabs, id: \.path) { tab in
                    CodeTabView(
                        tab: tab,
                        subtitle: subtitles[tab.path],
                        isActive: tabs.active == tab.path,
                        isDirty: files.existingBuffer(project, tab.path)?.isDirty ?? false,
                        status: git.files[tab.path],
                        actions: actions(for: tab.path)
                    )
                    .draggable(tab.path)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first, tabs.contains(dragged) else { return false }
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
        Task {
            let refused = await files.close(paths, project: project)
            if !refused.isEmpty { onRefused(refused) }
        }
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
            Text(CodeFilesPaneView.name(tab.path))
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
            .accessibilityLabel("Close \(CodeFilesPaneView.name(tab.path))")
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
            Text(saveState)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var saveState: String {
        if buffer.problem != nil || buffer.saveError != nil { return "Not saved" }
        if buffer.deletedOnDisk { return "Deleted" }
        return buffer.isDirty ? "Edited" : "Saved"
    }
}

private struct CodeFileBanners: View {
    let buffer: CodeFileBuffer

    var body: some View {
        if let problem = buffer.problem {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem.message).font(.caption)
                Spacer(minLength: 4)
                if problem == .conflict {
                    Button("Reload from disk") { buffer.reloadFromDisk() }
                }
                if problem.isTransient {
                    Button("Try again") { buffer.retryRead() }
                } else {
                    Button(keepTitle(problem)) { buffer.keepMine() }
                        .help(problem == .deletedWhileEditing ? "Create the file again with your edits" : "Write your edits over the version on disk")
                }
            }
            .controlSize(.small)
            .padding(8)
            .background(Color.orange.opacity(0.12))
        } else if buffer.deletedOnDisk {
            notice("The file was deleted on disk. ⌘S writes it back.", color: .orange)
        }
        if let error = buffer.saveError { notice(error, color: .red) }
    }

    private func keepTitle(_ problem: CodeFileBuffer.Problem) -> String {
        switch problem {
        case .conflict: "Keep mine"
        case .deletedWhileEditing: "Write it back"
        case .unreadable: "Write mine over it"
        }
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
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        files.register(context.coordinator, for: project)
        webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Read here so a reload or a rename re-runs this (observation).
        let open = tabs.paths.compactMap { files.existingBuffer(project, $0) }
        let state = Dictionary(uniqueKeysWithValues: open.map { buffer in
            (buffer.id, Coordinator.BufferState(path: buffer.relPath, revision: buffer.externalRevision))
        })
        let active = tabs.active.flatMap { files.existingBuffer(project, $0) }
        let shown = active?.state == .loaded ? active?.id : nil
        context.coordinator.sync(buffers: state, active: shown)
    }

    /// The pane goes away: what the page has not sent yet is pulled and
    /// saved before the page is released.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, CodeEditorBridge {
        struct BufferState: Equatable {
            let path: String
            let revision: Int
        }

        let files: CodeFilesCenter
        let project: Workbench
        weak var webView: WKWebView?
        private var ready = false
        private var shown: String?
        /// What the page was last told, per buffer id.
        private var told: [String: BufferState] = [:]
        private var wanted: [String: BufferState] = [:]
        private var wantedActive: String?

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
                told = [:]
                files.editorErrors[project.id] = nil
                push()
            case "text":
                guard let id = body["id"] as? String, let text = body["text"] as? String, let base = body["base"] as? Int else { return }
                guard let buffer = files.buffer(id: id) else {
                    NSLog("CodeFilesPane: an edit for a buffer no longer open was dropped")
                    return
                }
                files.edited(
                    buffer, text: text, base: base, project: project,
                    now: body["now"] as? Bool ?? false, explicit: body["explicit"] as? Bool ?? false
                )
            case "error":
                files.editorErrors[project.id] = (body["message"] as? String) ?? "The editor reported an error."
            default:
                break
            }
        }

        func sync(buffers: [String: BufferState], active: String?) {
            wanted = buffers
            wantedActive = active
            if ready { push() }
        }

        /// Brings the page in line with `wanted`: closed tabs go, reloads
        /// and renames reach their models, the active file is shown.
        private func push() {
            for id in told.keys where wanted[id] == nil {
                call("wt.close", id)
                told[id] = nil
            }
            for (id, state) in wanted {
                guard let previous = told[id], let buffer = files.buffer(id: id) else { continue }
                if previous.path != state.path { call("wt.rename", ["id": id, "path": state.path]) }
                if previous.revision != state.revision {
                    let mode = state.revision == buffer.forcedRevision ? "force"
                        : state.revision == buffer.rebasedRevision ? "rebase" : "replace"
                    call("wt.reload", ["id": id, "text": buffer.text, "rev": state.revision, "mode": mode])
                }
                told[id] = state
            }
            guard wantedActive != shown else { return }
            shown = wantedActive
            guard let id = wantedActive, let buffer = files.buffer(id: id), let state = wanted[id] else {
                call("wt.show", NSNull())
                return
            }
            call("wt.show", ["id": id, "path": buffer.relPath, "text": buffer.text, "rev": buffer.externalRevision])
            told[id] = state
        }

        // MARK: CodeEditorBridge

        func takePending() async -> [CodeEditorPendingEdit]? {
            guard ready, let webView else { return [] }
            return await Self.takePending(from: webView)
        }

        /// nil when the page could not be asked (logged).
        static func takePending(from webView: WKWebView) async -> [CodeEditorPendingEdit]? {
            let raw: [[String: Any]]
            do {
                raw = try await webView.evaluateJavaScript("wt.takePending()") as? [[String: Any]] ?? []
            } catch {
                NSLog("CodeFilesPane: wt.takePending failed: %@", error.localizedDescription)
                return nil
            }
            return raw.compactMap { item in
                guard let id = item["id"] as? String, let text = item["text"] as? String, let base = item["base"] as? Int else {
                    return nil
                }
                return CodeEditorPendingEdit(id: id, text: text, base: base)
            }
        }

        func dismantle(_ webView: WKWebView) {
            files.unregister(self, for: project.id)
            let files = files
            let project = project
            let wasReady = ready
            Task { @MainActor in
                // `webView` and `files` are held by this task, not by the
                // coordinator SwiftUI is releasing.
                if wasReady, let edits = await Self.takePending(from: webView) {
                    files.apply(edits, project: project, now: true)
                }
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "wt")
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            files.editorErrors[project.id] = "The editor could not load: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            files.editorErrors[project.id] = "The editor could not load: \(error.localizedDescription)"
        }

        /// The page's process died: edits it had not sent are gone; reload.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            files.editorErrors[project.id] = "The editor stopped and was restarted. Edits typed in the last moment may be lost."
            ready = false
            shown = nil
            told = [:]
            webView.load(URLRequest(url: CodeEditorSchemeHandler.pageURL))
        }

        /// `fn(arg)` with the argument JSON-encoded, so file text never
        /// needs escaping by hand.
        private func call(_ function: String, _ argument: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.fragmentsAllowed]),
                  let array = String(data: data, encoding: .utf8) else {
                files.editorErrors[project.id] = "Editor: could not encode a call to \(function)."
                return
            }
            webView?.evaluateJavaScript("\(function)(\(array.dropFirst().dropLast()))") { [weak self] _, error in
                guard let self, let error else { return }
                self.files.editorErrors[self.project.id] = "Editor: \(error.localizedDescription)"
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
