import AppKit
import Foundation
import Observation
import WatchtowerCore

/// The editor page's half of Go to Definition from the menu (⌃⌘J): the
/// page posts `definition` for the word at its cursor (the Files pane's
/// `MonacoEditorView.Coordinator`, a fake in tests).
@MainActor
protocol CodeDefinitionPage: AnyObject {
    /// false = no word at the cursor (or the page could not be asked).
    func requestDefinitionAtCursor() async -> Bool
}

/// Where the definition menu pops up: a point in `view`'s coordinates.
struct DefinitionMenuAnchor {
    weak var view: NSView?
    let point: NSPoint
}

/// What the owner picked in the definition menu.
enum DefinitionMenuPick: Equatable {
    /// Index into the choices shown.
    case choice(Int)
    case showAllUsages
    case dismissed
}

/// Shows the definition menu (`DefinitionMenuController`, a recorder in tests).
@MainActor
protocol DefinitionMenuPresenting: AnyObject {
    func pickDefinition(header: String, choices: [DefinitionChoice], at anchor: DefinitionMenuAnchor?) async -> DefinitionMenuPick
}

/// One `definition` message from the page: the word and where it was
/// asked for (the click, or the cursor for ⌃⌘J).
struct CodeDefinitionRequest: Equatable {
    /// The page's counter, answered with `definitionDone(req)`.
    let req: Int
    let word: String
    let origin: CodeNavLocation
}

/// Go to definition and the Files pane's back/forward history (spec §8.2),
/// on `AppState` so the history outlives the pane and navigation. One
/// request per workbench is live: a newer one cancels the text search of
/// the one before.
@MainActor
@Observable
final class CodeNavigationCenter {
    /// Per workbench (one Files pane each).
    private(set) var histories: [Int64: CodeNavigationHistory] = [:]
    /// "No definition of `w`", shown above the editor for `noticeDuration`.
    private(set) var notices: [Int64: String] = [:]
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    /// The menu's "Show All Usages…" (spec §8.3).
    @ObservationIgnored weak var usages: CodeUsagesCenter?
    @ObservationIgnored private let codeIndex: CodeIndexCenter
    @ObservationIgnored private let menu: DefinitionMenuPresenting
    @ObservationIgnored private let startSearch: CodeSearchStarter
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private var pages: [Int64: WeakDefinitionPage] = [:]
    @ObservationIgnored private var searches: [Int64: DefinitionTextSearch] = [:]
    /// Per workbench: the live request; an older one's answer is dropped.
    @ObservationIgnored private var generations: [Int64: Int] = [:]
    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private var noticeSerial = 0

    init(
        codeIndex: CodeIndexCenter,
        /// nil = the `NSMenu` (`DefinitionMenuController`).
        menu: DefinitionMenuPresenting? = nil,
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        noticeDuration: Duration = .seconds(2)
    ) {
        self.codeIndex = codeIndex
        self.menu = menu ?? DefinitionMenuController()
        self.startSearch = startSearch
        self.beep = beep
        self.noticeDuration = noticeDuration
    }

    // MARK: Pages

    func registerPage(_ page: CodeDefinitionPage, for workbenchID: Int64) {
        pages[workbenchID] = WeakDefinitionPage(page: page)
    }

    /// The Files pane went: its text search stops (the history stays).
    func unregisterPage(_ page: CodeDefinitionPage, for workbenchID: Int64) {
        guard pages[workbenchID]?.page === page else { return }
        pages[workbenchID] = nil
        searches.removeValue(forKey: workbenchID)?.cancel()
        generations[workbenchID] = nil
    }

    // MARK: Go to definition

    /// ⌃⌘J: the page posts `definition` for the word at its cursor; a beep
    /// when there is no editor or no word.
    func goToDefinitionAtCursor(project: Workbench) async {
        guard let page = pages[project.id]?.page, await page.requestDefinitionAtCursor() else {
            beep()
            return
        }
    }

    /// ⌘-click or ⌃⌘J (spec §8.2): one index candidate opens, several ask,
    /// none fall back to the text-search heuristic (spec §6.5) in a file the
    /// index does not read (R31), then a beep and the notice. Returns once
    /// the request is settled or superseded; the caller then answers the
    /// page with `definitionDone`.
    func goToDefinition(_ request: CodeDefinitionRequest, project: Workbench, anchor: DefinitionMenuAnchor?) async {
        nextGeneration += 1
        let generation = nextGeneration
        generations[project.id] = generation
        searches.removeValue(forKey: project.id)?.cancel()
        let index = codeIndex.index(for: project.id)
        var outcome = DefinitionCandidates.outcome(for: index.symbols(named: request.word), from: request.origin.path)
        var fromTextSearch = false
        var failure: String?
        // Ruling R31 (spec §6.5): the text search only stands in for a
        // language the index does not read (or a file it has not seen yet);
        // in an indexed one a miss is a miss.
        if outcome == .searchText, index.language(of: request.origin.path)?.isEmpty == false {
            outcome = .notFound
        }
        if outcome == .searchText {
            fromTextSearch = true
            let found = await searchText(request.word, project: project)
            guard generations[project.id] == generation, let found else { return }
            switch found {
            case let .success(matches):
                outcome = DefinitionHeuristic.outcome(for: matches, word: request.word, origin: request.origin)
            case let .failure(error):
                failure = error.message
                outcome = .notFound
            }
        }
        switch outcome {
        case let .jump(target):
            jump(to: target, from: request.origin, project: project)
        case let .choose(choices):
            let header = DefinitionCandidates.menuHeader(word: request.word, count: choices.count, fromTextSearch: fromTextSearch)
            let pick = await menu.pickDefinition(header: header, choices: choices, at: anchor)
            guard generations[project.id] == generation else { return }
            switch pick {
            case let .choice(index) where choices.indices.contains(index):
                jump(to: choices[index].target, from: request.origin, project: project)
            case .showAllUsages:
                usages?.showUsages(of: request.word, project: project)
            case .choice, .dismissed:
                break
            }
        case .searchText, .notFound:
            beep()
            let notice = DefinitionCandidates.noDefinitionNotice(word: request.word)
            showNotice(failure.map { "\(notice) — text search failed: \($0)" } ?? notice, workbenchID: project.id)
        }
        if generations[project.id] == generation { generations[project.id] = nil }
    }

    /// `code search --word --case` for the heuristic; nil when superseded
    /// or cancelled (no answer, no beep).
    private func searchText(_ word: String, project: Workbench) async -> Result<[CodeSearchMatch], DefinitionSearchError>? {
        let search = DefinitionTextSearch()
        searches[project.id] = search
        let options = CodeSearchOptions(query: word, word: true, caseSensitive: true, max: DefinitionHeuristic.searchMax, context: 0)
        let result = await withCheckedContinuation { continuation in
            search.continuation = continuation
            search.run = startSearch(project.folderURL, options, { [weak search] match in
                search?.matches.append(match)
            }, { [weak search] outcome in
                guard let search else { return }
                switch outcome {
                case .finished: search.finish(.success(search.matches))
                case let .failed(message): search.finish(.failure(DefinitionSearchError(message: message)))
                }
            })
        }
        if searches[project.id] === search { searches[project.id] = nil }
        return result
    }

    private func jump(to target: CodeNavLocation, from origin: CodeNavLocation, project: Workbench) {
        histories[project.id, default: CodeNavigationHistory()].recordJump(from: origin)
        workbenches?.showLocation(target, project: project, keepingTab: true)
    }

    private func showNotice(_ text: String, workbenchID: Int64) {
        noticeSerial += 1
        let serial = noticeSerial
        notices[workbenchID] = text
        let duration = noticeDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, noticeSerial == serial else { return }
            notices[workbenchID] = nil
        }
    }

    func notice(for workbenchID: Int64) -> String? {
        notices[workbenchID]
    }

    // MARK: History

    func canGoBack(workbenchID: Int64?) -> Bool {
        workbenchID.flatMap { histories[$0]?.canGoBack } ?? false
    }

    func canGoForward(workbenchID: Int64?) -> Bool {
        workbenchID.flatMap { histories[$0]?.canGoForward } ?? false
    }

    /// ⌃⌘← (and the jump bar's ‹, Task 9).
    func goBack(project: Workbench) {
        step(project: project) { history, current in history.goBack(from: current) }
    }

    /// ⌃⌘→ (and the jump bar's ›, Task 9).
    func goForward(project: Workbench) {
        step(project: project) { history, current in history.goForward(from: current) }
    }

    private func step(project: Workbench, _ move: (inout CodeNavigationHistory, CodeNavLocation?) -> CodeNavLocation?) {
        guard var history = histories[project.id] else { return }
        guard let target = move(&history, currentLocation(project)) else { return }
        histories[project.id] = history
        workbenches?.showLocation(target, project: project, keepingTab: false)
    }

    /// The cursor of the file on screen, as the page last reported it; nil
    /// when the page has not reported one for that file.
    private func currentLocation(_ project: Workbench) -> CodeNavLocation? {
        guard let files = workbenches?.codeFiles, let active = files.tabs(for: project).active,
              let cursor = files.cursors[project.id], cursor.path == active else { return nil }
        return cursor
    }
}

struct DefinitionSearchError: Error, Equatable {
    let message: String
}

/// The heuristic's `code search`: its matches so far and the caller waiting
/// for the end. Cancelling answers the caller with nil at once.
@MainActor
private final class DefinitionTextSearch {
    var continuation: CheckedContinuation<Result<[CodeSearchMatch], DefinitionSearchError>?, Never>?
    var run: CodeSearchCancelling?
    var matches: [CodeSearchMatch] = []

    func finish(_ result: Result<[CodeSearchMatch], DefinitionSearchError>?) {
        continuation?.resume(returning: result)
        continuation = nil
        run = nil
    }

    func cancel() {
        let run = run
        finish(nil)
        run?.cancel()
    }
}

private struct WeakDefinitionPage {
    weak var page: CodeDefinitionPage?
}
