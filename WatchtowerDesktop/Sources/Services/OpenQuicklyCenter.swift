import AppKit
import Foundation
import Observation
import WatchtowerCore

/// A running `code search` that can be stopped: `CodeSearchRun`, or a fake
/// in tests.
@MainActor
protocol CodeSearchCancelling: AnyObject {
    func cancel()
}

extension CodeSearchRun: CodeSearchCancelling {}

/// Starts one `code search` in a folder (`CodeSearchRun.start` by default).
typealias CodeSearchStarter = @MainActor (
    _ folder: URL,
    _ options: CodeSearchOptions,
    _ onMatch: @escaping @MainActor (CodeSearchMatch) -> Void,
    _ onDone: @escaping @MainActor (CodeSearchRun.Outcome) -> Void
) -> CodeSearchCancelling

/// Puts Open Quickly on screen: the NSPanel in the app
/// (`OpenQuicklyPanelController`), a recorder in tests.
@MainActor
protocol OpenQuicklyPresenting: AnyObject {
    func presentPanel(_ session: OpenQuicklySession, center: OpenQuicklyCenter, over window: NSWindow?)
    /// `restoringFocus`: the keyboard goes back to what had it (Esc).
    func dismissPanel(restoringFocus: Bool)
}

/// The first lines of a file for the preview pane, or why there are none.
struct OpenQuicklyFilePreview: Equatable {
    let lines: [OpenQuicklyPreviewLine]
    let error: String?
}

/// One Open Quickly panel (spec §8.1): the query and its answers — files
/// and symbols from the workbench's index at every keystroke, text matches
/// from a `code search` started 120 ms after the last one (each keystroke
/// kills the previous search) — and the preview's file lines.
@MainActor
@Observable
final class OpenQuicklySession {
    /// The Text scope's matches per search; more is a narrower query.
    static let textSearchMax = 500

    let project: Workbench
    let index: WorkbenchCodeIndex
    /// The git marks when the panel opened (file rows show them).
    let gitStatuses: [String: GitFileStatus]
    private(set) var model: OpenQuicklyModel
    /// By `previewKey`.
    private(set) var previews: [String: OpenQuicklyFilePreview] = [:]
    @ObservationIgnored private let boosts: CodeRankingBoosts
    @ObservationIgnored private let startSearch: CodeSearchStarter
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var run: CodeSearchCancelling?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// The query the run in flight (or finished) searched for.
    @ObservationIgnored private var searchedQuery: String?
    @ObservationIgnored private var arrived: [CodeSearchMatch] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The panel closed: no search starts any more.
    @ObservationIgnored private var closed = false

    init(
        project: Workbench,
        index: WorkbenchCodeIndex,
        scope: CodeSearchScope,
        boosts: CodeRankingBoosts,
        gitStatuses: [String: GitFileStatus] = [:],
        startSearch: @escaping CodeSearchStarter,
        debounce: Duration = .milliseconds(120)
    ) {
        self.project = project
        self.index = index
        self.boosts = boosts
        self.gitStatuses = gitStatuses
        self.startSearch = startSearch
        self.debounce = debounce
        model = OpenQuicklyModel(scope: scope)
        refreshIndexResults()
    }

    // MARK: Input

    func updateQuery(_ text: String) {
        guard text != model.query else { return }
        model.setQuery(text)
        refreshIndexResults()
        restartTextSearch()
    }

    /// The query stays (⇧⌘F while open, the scope control, "more…").
    func updateScope(_ scope: CodeSearchScope) {
        guard scope != model.scope else { return }
        model.setScope(scope)
        scopeChanged()
    }

    func move(_ arrow: OpenQuicklyArrow) {
        model.move(arrow)
    }

    func select(_ rowID: String) {
        model.select(rowID)
    }

    /// Return on the selected row (`OpenQuicklyModel.activateSelection`).
    func activateSelection(option: Bool, command: Bool) -> OpenQuicklyCommand {
        let scope = model.scope
        let command = model.activateSelection(option: option, command: command)
        if model.scope != scope { scopeChanged() }
        return command
    }

    func spaceAction(quickLookShown: Bool) -> OpenQuicklySpace {
        model.spaceAction(quickLookShown: quickLookShown)
    }

    /// The index changed under the panel (it was still indexing).
    func refreshIndexResults() {
        let query = model.query
        let cap = OpenQuicklyModel.sectionCap + 1 // the best match may come out of either list
        switch model.scope {
        case .all:
            model.setIndexResults(
                files: index.query(query, scope: .files, boosts: boosts, limit: cap),
                symbols: index.query(query, scope: .symbols, boosts: boosts, limit: cap)
            )
        case .files:
            model.setIndexResults(files: index.query(query, scope: .files, boosts: boosts), symbols: [])
        case .symbols:
            model.setIndexResults(files: [], symbols: index.query(query, scope: .symbols, boosts: boosts))
        case .text:
            model.setIndexResults(files: [], symbols: [])
        }
    }

    /// The panel goes: the search in flight is killed, none starts again.
    func stop() {
        closed = true
        cancelTextSearch()
    }

    private func cancelTextSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        flushTask?.cancel()
        flushTask = nil
        run?.cancel()
        run = nil
    }

    private func scopeChanged() {
        refreshIndexResults()
        // Files/Symbols left a query unsearched; one searched already stays.
        if searchedQuery != model.trimmedQuery { restartTextSearch() }
    }

    // MARK: Text search

    private var scopeShowsText: Bool {
        model.scope == .all || model.scope == .text
    }

    /// Kills the search in flight; a new one starts after the debounce when
    /// the scope shows text.
    private func restartTextSearch() {
        cancelTextSearch()
        arrived = []
        searchedQuery = nil
        let query = model.trimmedQuery
        guard !closed, !query.isEmpty, scopeShowsText else { return }
        let wait = debounce
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            startTextSearch(query)
        }
    }

    private func startTextSearch(_ query: String) {
        searchedQuery = query
        let options = CodeSearchOptions(query: query, max: Self.textSearchMax, context: 1)
        run = startSearch(project.folderURL, options, { [weak self] match in
            self?.matchArrived(match, query: query)
        }, { [weak self] outcome in
            self?.searchFinished(outcome, query: query)
        })
    }

    /// Matches are applied once per main-actor turn, not one view update each.
    private func matchArrived(_ match: CodeSearchMatch, query: String) {
        guard searchedQuery == query else { return }
        arrived.append(match)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            self?.flushArrived()
        }
    }

    private func flushArrived() {
        flushTask = nil
        guard !arrived.isEmpty else { return }
        model.appendTextMatches(arrived)
        arrived = []
    }

    private func searchFinished(_ outcome: CodeSearchRun.Outcome, query: String) {
        guard searchedQuery == query else { return }
        flushTask?.cancel()
        flushArrived()
        run = nil
        switch outcome {
        case let .finished(done): model.finishText(.finished(truncated: done.truncated))
        case let .failed(message): model.finishText(.failed(message))
        }
    }

    // MARK: Preview

    static func previewKey(path: String, line: Int) -> String {
        "\(path)#\(line)"
    }

    /// The 12 lines from `line` of `path` (a symbol's, or a file's first),
    /// read off the main actor once per panel.
    func loadPreview(path: String, line: Int) async {
        let key = Self.previewKey(path: path, line: line)
        guard previews[key] == nil else { return }
        let url = project.folderURL.appendingPathComponent(path)
        let preview = await Task.detached(priority: .userInitiated) { () -> OpenQuicklyFilePreview in
            do {
                guard let text = String(bytes: try Data(contentsOf: url), encoding: .utf8) else {
                    return OpenQuicklyFilePreview(lines: [], error: "Not UTF-8 text.")
                }
                return OpenQuicklyFilePreview(lines: OpenQuicklyPreviewText.lines(of: text, from: line, count: 12), error: nil)
            } catch {
                return OpenQuicklyFilePreview(lines: [], error: "Could not read the file: \(error.localizedDescription)")
            }
        }.value
        previews[key] = preview
    }
}

/// Open Quickly for the workbench on screen (spec §8.1, decision 3): the
/// workbench page registers itself while it is in a window; ⇧⌘O, ⇧⌘F and
/// double Shift present the panel only then. On `AppState`.
///
/// While the panel is up the workbench counts as shown for the index
/// (`markShown`/`markHidden`, ruling R25), so it is built — and kept — even
/// with the Files pane closed.
@MainActor
@Observable
final class OpenQuicklyCenter {
    /// The workbench page on screen and its window.
    struct Host {
        let project: Workbench
        weak var window: NSWindow?
    }

    private(set) var host: Host?
    private(set) var session: OpenQuicklySession?
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    /// ⌘↩ and the Ask AI row (spec §9.3; the answer is Task 12's).
    @ObservationIgnored var onAskAI: @MainActor (_ query: String, _ project: Workbench) -> Void = { _, _ in }
    /// ⌥⌘↩ (spec §9.5; the hand-over is Task 13's).
    @ObservationIgnored var onHandToClaude: @MainActor (_ query: String, _ project: Workbench) -> Void = { _, _ in }
    @ObservationIgnored private let codeIndex: CodeIndexCenter
    @ObservationIgnored private let startSearch: CodeSearchStarter
    @ObservationIgnored private let presenter: OpenQuicklyPresenting

    init(
        codeIndex: CodeIndexCenter,
        /// nil = the NSPanel (`OpenQuicklyPanelController`).
        presenter: OpenQuicklyPresenting? = nil,
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        }
    ) {
        self.codeIndex = codeIndex
        self.presenter = presenter ?? OpenQuicklyPanelController()
        self.startSearch = startSearch
    }

    /// A workbench is on screen: the menu commands and double Shift work.
    var canPresent: Bool {
        host != nil
    }

    /// The workbench page is in `window` (again, or another workbench now).
    func pageAppeared(_ project: Workbench, window: NSWindow?) {
        if let session, session.project.id != project.id || session.project.folderURL != project.folderURL {
            dismiss(restoringFocus: false)
        }
        host = Host(project: project, window: window)
    }

    /// The workbench page left the screen: the panel closes with it.
    func pageDisappeared(workbenchID: Int64) {
        guard host?.project.id == workbenchID else { return }
        host = nil
        dismiss(restoringFocus: false)
    }

    /// ⇧⌘O / double Shift (`.all`), ⇧⌘F (`.text`). Already open: the panel
    /// comes forward, ⇧⌘F switching it to Text. No workbench on screen:
    /// nothing.
    func present(scope: CodeSearchScope) {
        guard let host else { return }
        if let session {
            if scope == .text { session.updateScope(.text) }
            presenter.presentPanel(session, center: self, over: host.window)
            return
        }
        let project = host.project
        codeIndex.markShown(workbenchID: project.id, folder: project.folderURL)
        let files = workbenches?.codeFiles
        let boosts = files.map { files in
            CodeRankingBoosts(
                openTabs: files.tabs(for: project).paths,
                recent: files.recentFiles(for: project),
                gitModified: Set(files.git(for: project).files.keys)
            )
        } ?? .none
        let session = OpenQuicklySession(
            project: project, index: codeIndex.index(for: project.id), scope: scope, boosts: boosts,
            gitStatuses: files?.git(for: project).files ?? [:], startSearch: startSearch
        )
        self.session = session
        presenter.presentPanel(session, center: self, over: host.window)
    }

    /// Esc (`restoringFocus`), a click outside, an open, the page leaving.
    func dismiss(restoringFocus: Bool) {
        guard let session else { return }
        self.session = nil
        session.stop()
        codeIndex.markHidden(workbenchID: session.project.id)
        presenter.dismissPanel(restoringFocus: restoringFocus)
    }

    /// What a Return asked for.
    func perform(_ command: OpenQuicklyCommand) {
        guard let session else { return }
        switch command {
        case .none:
            break
        case let .open(target, beside):
            let project = session.project
            dismiss(restoringFocus: false)
            Task { await workbenches?.openFile(at: target, project: project, beside: beside) }
        case let .askAI(query):
            onAskAI(query, session.project)
        case let .handToClaude(query):
            onHandToClaude(query, session.project)
        }
    }
}
