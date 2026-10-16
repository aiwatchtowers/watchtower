import AppKit
import SwiftUI
import WatchtowerCore

/// The Changes pane (board #328, spec §10): a session's review round — the
/// file list on the left, the selected file's Monaco diff and its comments
/// on the right. The round is re-read when the window becomes key and when
/// the session's turn ends, while the round is open and the pane on screen.
struct ReviewChangesPaneView: View {
    let model: ReviewChangesModel
    /// The session's state kind, for the turn-over refresh; nil = not known.
    var agentStateKind: SessionSwitcherPresentation.State.Kind?

    @State private var inline = false
    @State private var compose: ComposeRequest?
    @State private var pageError: String?
    @State private var onScreen = false
    @State private var pace = ReviewPaceWiring()

    /// What the shared comment sheet asks for and does with the answer: a line
    /// comment, a design comment, a checklist question, a Wrap-up note.
    struct ComposeRequest: Identifiable {
        let id = UUID()
        let title: String
        var prefill = ""
        /// Show the lens picker (None + the round's lenses).
        var lensChoice = false
        var allowsEmpty = false
        let submit: (_ body: String, _ lens: String) throws -> Void
    }

    var body: some View {
        content
            .background(WindowKeyObserver(action: { autoRefresh() }, windowChanged: { pace.window = $0 }))
            .onAppear {
                onScreen = true
                pace.start(model: model)
                if model.load == .idle { Task { await openRound() } }
            }
            .onDisappear {
                onScreen = false
                pace.stop()
                model.flushState()
            }
            .onChange(of: agentStateKind) { old, new in
                // Into a turn-over kind only: .finished → .stopped is the same turn's end.
                if let new, Self.turnOver.contains(new), !(old.map(Self.turnOver.contains) ?? false) { autoRefresh() }
            }
            .sheet(item: $compose) { request in
                ReviewNewCommentSheet(request: request, lenses: model.lenses)
            }
    }

    /// The kinds a turn ends in: the agent's edits are done for now.
    static let turnOver: Set<SessionSwitcherPresentation.State.Kind> = [
        .stopped, .finished, .failed, .waitingOnAsk, .background
    ]

    @ViewBuilder private var content: some View {
        switch model.load {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await openRound() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                ReviewChangesHeader(model: model, inline: $inline) { Task { await refreshOrNextRound() } }
                if model.mode == .deep { ReviewPhaseStrip(model: model) }
                if let pageError {
                    ReviewBanner(text: pageError, isError: true) { self.pageError = nil }
                }
                Divider()
                body(for: model.mode == .deep ? model.phase : nil)
            }
        }
    }

    /// Quick mode (nil phase) and Deep's Chapters show the file column and the diff.
    @ViewBuilder private func body(for phase: ReviewPhase?) -> some View {
        switch phase {
        case .meaning:
            ReviewMeaningView(model: model) { compose = $0 }
        case .wrapup:
            ReviewWrapUpView(model: model) { compose = $0 }
        case .chapters:
            HSplitView {
                ReviewChapterListView(model: model)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                detail(checklist: true).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        case nil:
            HSplitView {
                ReviewFileListView(model: model)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                detail(checklist: false).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func detail(checklist: Bool) -> some View {
        if let path = model.selectedPath {
            VStack(spacing: 0) {
                diff(path: path)
                ReviewCommentListView(model: model, path: path)
                if checklist { ReviewChecklistView(model: model) { compose = $0 } }
            }
        } else {
            VStack(spacing: 0) {
                Text(model.files.isEmpty ? "No changes yet" : "Pick a file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if checklist { ReviewChecklistView(model: model) { compose = $0 } }
            }
        }
    }

    @ViewBuilder private func diff(path: String) -> some View {
        if let sides = model.currentSides {
            if sides.old.binary || sides.new.binary {
                placeholder("Binary file")
            } else if sides.old.tooLarge || sides.new.tooLarge {
                VStack(spacing: 8) {
                    Text("Too large to show").foregroundStyle(.secondary)
                    if let root = model.round?.folderRoot {
                        Button("Show in Finder") {
                            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MonacoDiffView(payload: payload(path: path, sides: sides)) { start, end, side in
                    compose = lineComposeRequest(path: path, side: side, start: start, end: end)
                } onError: { pageError = $0 }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lineComposeRequest(path: String, side: String, start: Int, end: Int) -> ComposeRequest {
        let lines = start == end ? "line \(start)" : "lines \(start)–\(end)"
        let title = "Comment on \(side == "old" ? "removed " : "")\(lines) of \((path as NSString).lastPathComponent)"
        return ComposeRequest(title: title, lensChoice: model.mode == .deep) { body, lens in
            try model.addComment(path: path, side: side, startLine: start, endLine: end, body: body, lens: lens)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The new side's open comments go into the diff, each under its last line.
    private func payload(path: String, sides: ReviewChangesModel.LoadedSides) -> MonacoDiffView.Payload {
        let shown = model.comments.filter {
            $0.path == path && $0.side == "new" && [.draft, .sent, .carried].contains($0.status)
        }
        return MonacoDiffView.Payload(
            path: path, original: sides.old.text, modified: sides.new.text, inline: inline,
            comments: shown.map {
                .init(id: $0.id, startLine: $0.startLine, endLine: $0.endLine, body: $0.body,
                      status: $0.status.rawValue, reply: $0.agentReply)
            }
        )
    }

    /// Opens the round, then puts its first file on screen.
    private func openRound() async {
        await model.open()
        if model.load == .ready, model.selectedPath == nil, let first = model.files.first(where: { $0.collapsedReason == nil }) {
            await model.select(first.path)
        }
    }

    /// An open round re-reads its tree; a sent one gives way to the next.
    private func refreshOrNextRound() async {
        if model.round?.status == "open" {
            await model.refresh()
        } else {
            await openRound()
        }
    }

    /// The window became key or the turn ended: re-read an open round on
    /// screen, never during a Send or another refresh.
    private func autoRefresh() {
        guard onScreen, model.load == .ready, model.round?.status == "open", !model.sending, !model.refreshing else { return }
        Task { await model.refresh() }
    }
}

/// The shared comment sheet: line comments, design comments, checklist
/// questions and Wrap-up notes differ only in the request they carry.
private struct ReviewNewCommentSheet: View {
    let request: ReviewChangesPaneView.ComposeRequest
    let lenses: [ReviewLens]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var lens = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title).font(.headline)
            TextEditor(text: $text)
                .font(.callout)
                .frame(width: 380, height: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            if request.lensChoice {
                Picker("Lens", selection: $lens) {
                    Text("None").tag("")
                    ForEach(lenses) { Text($0.name).tag($0.id) }
                }
                .controlSize(.small)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    do {
                        try request.submit(text, lens)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!request.allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear { text = request.prefill }
    }
}

/// Calls `action` whenever the window hosting it becomes key.
private struct WindowKeyObserver: NSViewRepresentable {
    let action: () -> Void
    /// Told the hosting window whenever it changes (nil once the view leaves it).
    var windowChanged: ((NSWindow?) -> Void)?

    func makeNSView(context: Context) -> ObservingView { ObservingView() }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.action = action
        view.windowChanged = windowChanged
    }

    final class ObservingView: NSView {
        var action: (() -> Void)?
        var windowChanged: ((NSWindow?) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            windowChanged?(window)
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.action?() }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// The pane's active-time wiring: a 15 s tick and a local event monitor,
/// both scoped to the pane's window and both removed in `stop()`.
@MainActor
final class ReviewPaceWiring {
    weak var window: NSWindow?
    private var timer: Timer?
    private var monitor: Any?

    func start(model: ReviewChangesModel) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { model.tick(isKey: self?.window?.isKeyWindow ?? false) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let window = self?.window, event.window === window { model.noteInteraction() }
            }
            return event
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
