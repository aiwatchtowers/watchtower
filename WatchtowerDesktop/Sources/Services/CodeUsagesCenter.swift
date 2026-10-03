import AppKit
import Foundation
import Observation
import WatchtowerCore

/// The editor page's half of Usages from the menu (⇧⌘U): the page posts
/// `usages` for the word at its cursor (the Files pane's
/// `MonacoEditorView.Coordinator`, a fake in tests).
@MainActor
protocol CodeUsagesPage: AnyObject {
    /// false = no word at the cursor (or the page could not be asked).
    func requestUsagesAtCursor() async -> Bool
}

/// The Files pane inspector's tabs (spec §8.3, §9.4).
enum CodeInspectorTab: String, CaseIterable, Identifiable {
    case usages
    case questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usages: "Usages"
        case .questions: "Questions"
        }
    }
}

/// Usages (spec §8.3) and the Files pane's inspector, per workbench, on
/// `AppState` so a list and its search outlive the pane. ⇧⌘U (the word at
/// the cursor), the editor's context menu and the definition menu's "Show
/// All Usages…" end in `showUsages`: one `code search --word --case` per
/// workbench, a new name cancelling the one before; the Files pane going
/// away stops it and keeps what it found.
@MainActor
@Observable
final class CodeUsagesCenter {
    private(set) var results: [Int64: UsagesModel] = [:]
    private(set) var shownInspectors: Set<Int64> = []
    private(set) var inspectorTabs: [Int64: CodeInspectorTab] = [:]
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    @ObservationIgnored private let startSearch: CodeSearchStarter
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private var pages: [Int64: WeakUsagesPage] = [:]
    @ObservationIgnored private var runs: [Int64: CodeSearchCancelling] = [:]
    /// Per workbench: the live search; an older one's callbacks are dropped.
    @ObservationIgnored private var generations: [Int64: Int] = [:]
    @ObservationIgnored private var nextGeneration = 0

    init(
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        self.startSearch = startSearch
        self.beep = beep
    }

    // MARK: Pages

    func registerPage(_ page: CodeUsagesPage, for workbenchID: Int64) {
        pages[workbenchID] = WeakUsagesPage(page: page)
    }

    /// The Files pane went: its search stops, the list stays.
    func unregisterPage(_ page: CodeUsagesPage, for workbenchID: Int64) {
        guard pages[workbenchID]?.page === page else { return }
        pages[workbenchID] = nil
        guard let run = runs.removeValue(forKey: workbenchID) else { return }
        generations[workbenchID] = nil
        run.cancel()
        results[workbenchID]?.stop()
    }

    // MARK: Usages

    func usages(for workbenchID: Int64) -> UsagesModel? {
        results[workbenchID]
    }

    /// ⇧⌘U: the page posts `usages` for the word at its cursor; a beep when
    /// there is no editor or no word.
    func showUsagesAtCursor(project: Workbench) async {
        guard let page = pages[project.id]?.page, await page.requestUsagesAtCursor() else {
            beep()
            return
        }
    }

    /// The usages of `word` in the workbench, in the inspector's Usages tab.
    func showUsages(of word: String, project: Workbench) {
        guard !word.isEmpty else {
            beep()
            return
        }
        let workbenchID = project.id
        runs.removeValue(forKey: workbenchID)?.cancel()
        nextGeneration += 1
        let generation = nextGeneration
        generations[workbenchID] = generation
        results[workbenchID] = UsagesModel(word: word)
        shownInspectors.insert(workbenchID)
        inspectorTabs[workbenchID] = .usages
        let options = CodeSearchOptions(query: word, word: true, caseSensitive: true, context: 0)
        runs[workbenchID] = startSearch(project.folderURL, options, { [weak self] match in
            guard let self, generations[workbenchID] == generation else { return }
            results[workbenchID]?.append(match)
        }, { [weak self] outcome in
            guard let self, generations[workbenchID] == generation else { return }
            generations[workbenchID] = nil
            runs[workbenchID] = nil
            switch outcome {
            case let .finished(done): results[workbenchID]?.finish(truncated: done.truncated)
            case let .failed(message): results[workbenchID]?.fail(message)
            }
        })
    }

    func setCollapsed(_ isCollapsed: Bool, path: String, workbenchID: Int64) {
        results[workbenchID]?.setCollapsed(isCollapsed, path: path)
    }

    /// A row's click: the file in the Files pane (a preview tab, like Open
    /// Quickly's ↩), the cursor on the name.
    func openUsage(_ row: UsageRow, project: Workbench) async {
        await workbenches?.openFile(at: row.target, project: project, beside: false)
    }

    // MARK: Inspector

    func isInspectorShown(workbenchID: Int64) -> Bool {
        shownInspectors.contains(workbenchID)
    }

    func setInspectorShown(_ isShown: Bool, workbenchID: Int64) {
        guard isShown != shownInspectors.contains(workbenchID) else { return }
        if isShown {
            shownInspectors.insert(workbenchID)
        } else {
            shownInspectors.remove(workbenchID)
        }
    }

    func inspectorTab(workbenchID: Int64) -> CodeInspectorTab {
        inspectorTabs[workbenchID] ?? .usages
    }

    func selectInspectorTab(_ tab: CodeInspectorTab, workbenchID: Int64) {
        inspectorTabs[workbenchID] = tab
    }
}

private struct WeakUsagesPage {
    weak var page: CodeUsagesPage?
}
