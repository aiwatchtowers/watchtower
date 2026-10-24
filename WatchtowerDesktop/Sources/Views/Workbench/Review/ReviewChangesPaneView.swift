import AppKit
import SwiftUI
import WatchtowerCore

/// The Branch review pane (board #328, #712 spec §4): whose work it is
/// (the identity bar), the toolbar, then a session's review round — the
/// file list on the left, the selected file's header, Monaco diff and its
/// comments on the right — or one "Nothing to review" state on an empty
/// branch. The round is re-read when the window becomes key and when the
/// session's turn ends, while the round is open and the pane on screen.
struct ReviewChangesPaneView: View {
    let model: ReviewChangesModel
    let identity: ReviewSessionIdentity
    /// The session's state kind, for the turn-over refresh; nil = not known.
    var agentStateKind: SessionSwitcherPresentation.State.Kind?
    /// Find Repeats' model (the workbench's lessons); nil = not available.
    var lessons: ReviewLessonsModel?

    @State private var inline = false
    @State private var compose: ComposeRequest?
    @State private var findingRepeats = false
    @State private var pageError: String?
    @State private var onScreen = false
    /// The pane's height; 0 until the first layout (no cap then).
    @State private var paneHeight: CGFloat = 0
    @State private var pace = ReviewPaceWiring()

    /// What the shared comment sheet asks for and does with the answer: a line
    /// comment, a design comment, a risk, a Wrap-up note.
    struct ComposeRequest: Identifiable {
        let id = UUID()
        let title: String
        var prefill = ""
        var allowsEmpty = false
        let submit: (_ body: String) async throws -> Void
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
                Task { await model.flushState() }
            }
            .onChange(of: agentStateKind) { old, new in
                // Into a turn-over kind only: .finished → .stopped is the same turn's end.
                if let new, Self.turnOver.contains(new), !(old.map(Self.turnOver.contains) ?? false) { autoRefresh() }
            }
            .sheet(item: $compose) { request in
                ReviewNewCommentSheet(request: request)
            }
            .sheet(isPresented: $findingRepeats) {
                if let lessons { ReviewLessonsSheet(model: lessons, lenses: model.lenses) }
            }
    }

    /// The kinds a turn ends in: the agent's edits are done for now.
    static let turnOver: Set<SessionSwitcherPresentation.State.Kind> = [
        .stopped, .finished, .failed, .waitingOnAsk, .background
    ]

    private var content: some View {
        VStack(spacing: 0) {
            // The target cards take at most a third of the pane (Deep's Meaning).
            ReviewIdentityBar(identity: identity, model: model,
                              maxCardsHeight: paneHeight > 0 ? paneHeight / 3 : .infinity)
            Divider()
            if showsToolbar {
                ReviewToolbar(
                    model: model, inline: $inline,
                    refresh: { Task { await refreshOrNextRound() } },
                    findRepeats: lessons == nil ? nil : { findingRepeats = true },
                    // The session gone (no row): nothing to open.
                    openTerminal: identity.row == nil ? nil : identity.openTerminal
                )
                Divider()
            }
            ReviewBanners(model: model)
            if let pageError {
                ReviewBanner(text: pageError, isError: true) { self.pageError = nil }
            }
            state
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
    }

    /// An open round with nothing to review shows no toolbar; a sent one
    /// does, for Start next round.
    private var showsToolbar: Bool {
        guard model.load == .ready, let round = model.round else { return false }
        return model.hasChanges || round.status != "open"
    }

    /// Nothing on the branch to review (spec §4.6): the round's whole diff is empty.
    private var nothingToReview: Bool {
        model.load == .ready && !model.hasChanges
    }

    @ViewBuilder private var state: some View {
        switch model.load {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: Spacing.regular) {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await openRound() } }
                    .buttonStyle(.kitSecondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if nothingToReview {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "checkmark.circle")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    // A sent round's toolbar has Start next round instead.
                    if model.round?.status == "open" {
                        Button("Refresh") { Task { await refreshOrNextRound() } }
                            .buttonStyle(.kitSecondary)
                            .disabled(model.sending || model.refreshing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                body(for: model.mode == .deep ? model.phase : nil)
            }
        }
    }

    /// The empty state's line, from the identity bar's branch line.
    private var emptyDescription: String {
        ReviewIdentityPresentation.emptyDescription(identity.branchLine(model))
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
                if let file = model.files.first(where: { $0.path == path }) {
                    ReviewFileHeader(model: model, file: file)
                    Divider()
                }
                diff(path: path)
                ReviewCommentListView(model: model, path: path)
                if checklist { chaptersFoot }
            }
        } else {
            VStack(spacing: 0) {
                Text(Self.noFileText(model))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if checklist { chaptersFoot }
            }
        }
    }

    /// Chapters' foot: the footer, the chapter's risks, then Next: Wrap-up.
    private var chaptersFoot: some View {
        VStack(spacing: 0) {
            ReviewChapterFooter(model: model)
            ReviewChapterRisksView(model: model, onComment: { compose = $0 }, onAsk: { _ in })
            ReviewNextStepButton(model: model)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
        }
    }

    /// The detail without a file picked: never "No changes yet" while the
    /// branch has changes (spec §4.6).
    static func noFileText(_ model: ReviewChangesModel) -> String {
        guard model.files.isEmpty else { return "Pick a file" }
        return nothingNewText(model) ?? "No changes yet"
    }

    /// The Since view with nothing new on a branch that has changes: the
    /// detail and the file column say so, not "No changes".
    static func nothingNewText(_ model: ReviewChangesModel) -> String? {
        guard model.hasChanges, model.view == .sinceLastRound, let round = model.round else { return nil }
        return "Nothing new since round \(round.prevRoundId)"
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
                } onUndo: { id in
                    Task { await model.undo(hunkID: id) }
                } onError: { pageError = $0 }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lineComposeRequest(path: String, side: String, start: Int, end: Int) -> ComposeRequest {
        let lines = start == end ? "line \(start)" : "lines \(start)–\(end)"
        let title = "Comment on \(side == "old" ? "removed " : "")\(lines) of \((path as NSString).lastPathComponent)"
        return ComposeRequest(title: title) { body in
            try await model.addComment(path: path, side: side, startLine: start, endLine: end, body: body)
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
            path: path, original: sides.old.text, modified: sides.new.text, inline: inline, fullFile: model.fullFile,
            comments: shown.map {
                .init(id: $0.id, startLine: $0.startLine, endLine: $0.endLine, body: $0.body,
                      status: $0.status.rawValue, reply: model.agentReply(for: $0))
            },
            notes: ReviewPresentation.noteZones(model.notes, path: path, placements: model.notePlacements),
            hunks: ReviewPresentation.hunks(
                of: model.files.first { $0.path == path }, roundOpen: model.round?.status == "open",
                canUndo: model.canUndo, busy: model.sending || model.undoing
            )
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

/// The shared comment sheet: line comments, design comments, risk
/// comments and Wrap-up notes differ only in the request they carry.
private struct ReviewNewCommentSheet: View {
    let request: ReviewChangesPaneView.ComposeRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    /// The comment is being written (board #670): Add, Cancel and Esc wait.
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title).font(.headline)
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
                    .disabled(isSaving)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !request.allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .interactiveDismissDisabled(isSaving)
        .onAppear { text = request.prefill }
    }

    /// The sheet closes once the comment is written; a failure keeps it open
    /// with the text and says why.
    private func add() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await request.submit(text)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
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
            MainActor.assumeIsolated { _ = model.tick(isKey: self?.window?.isKeyWindow ?? false) }
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
