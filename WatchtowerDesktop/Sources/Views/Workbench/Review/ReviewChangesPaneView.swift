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
    @State private var newComment: NewComment?
    @State private var pageError: String?
    @State private var onScreen = false

    struct NewComment: Identifiable {
        let id = UUID()
        let path: String
        let side: String
        let startLine: Int
        let endLine: Int
    }

    var body: some View {
        content
            .background(WindowKeyObserver { autoRefresh() })
            .onAppear {
                onScreen = true
                if model.load == .idle { Task { await openRound() } }
            }
            .onDisappear { onScreen = false }
            .onChange(of: agentStateKind) { old, new in
                if let new, old != new, Self.turnOver.contains(new) { autoRefresh() }
            }
            .sheet(item: $newComment) { draft in
                ReviewNewCommentSheet(draft: draft) { body in
                    try model.addComment(path: draft.path, side: draft.side, startLine: draft.startLine,
                                         endLine: draft.endLine, body: body)
                }
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
                if let pageError {
                    ReviewBanner(text: pageError, isError: true) { self.pageError = nil }
                }
                Divider()
                HSplitView {
                    ReviewFileListView(model: model)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                    detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let path = model.selectedPath {
            VStack(spacing: 0) {
                diff(path: path)
                ReviewCommentListView(model: model, path: path)
            }
        } else {
            Text(model.files.isEmpty ? "No changes yet" : "Pick a file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func diff(path: String) -> some View {
        if let sides = model.sides {
            if sides.old.binary || sides.new.binary {
                placeholder("Binary file")
            } else if sides.old.tooLarge || sides.new.tooLarge {
                VStack(spacing: 8) {
                    Text("Too large to show — open in Files").foregroundStyle(.secondary)
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
                    newComment = NewComment(path: path, side: side, startLine: start, endLine: end)
                } onError: { pageError = $0 }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The new side's open comments go into the diff, each under its last line.
    private func payload(path: String, sides: (old: ReviewFileSide, new: ReviewFileSide)) -> MonacoDiffView.Payload {
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
    /// screen, never during a Send.
    private func autoRefresh() {
        guard onScreen, model.load == .ready, model.round?.status == "open", !model.sending else { return }
        Task { await model.refresh() }
    }
}

/// The comment sheet for the lines the owner chose in the diff.
private struct ReviewNewCommentSheet: View {
    let draft: ReviewChangesPaneView.NewComment
    let add: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.callout)
                .frame(width: 380, height: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    do {
                        try add(text)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private var title: String {
        let lines = draft.startLine == draft.endLine ? "line \(draft.startLine)" : "lines \(draft.startLine)–\(draft.endLine)"
        return "Comment on \(draft.side == "old" ? "removed " : "")\(lines) of \((draft.path as NSString).lastPathComponent)"
    }
}

/// Calls `action` whenever the window hosting it becomes key.
private struct WindowKeyObserver: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ObservingView { ObservingView() }

    func updateNSView(_ view: ObservingView, context: Context) { view.action = action }

    final class ObservingView: NSView {
        var action: (() -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
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
