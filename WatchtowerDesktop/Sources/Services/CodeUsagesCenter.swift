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
/// away stops it and keeps what it found. Which workbenches show the
/// inspector, and on which tab, is kept across launches (#401), per
/// workspace: workbench ids come from the workspace's own database.
@MainActor
@Observable
final class CodeUsagesCenter {
    private(set) var results: [Int64: UsagesModel] = [:]
    private(set) var shownInspectors: Set<Int64> = []
    private(set) var inspectorTabs: [Int64: CodeInspectorTab] = [:]
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    /// A row click is a jump: it goes on the pane's Back history (R33).
    @ObservationIgnored weak var navigation: CodeNavigationCenter?
    @ObservationIgnored private let startSearch: CodeSearchStarter
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private var pages: [Int64: WeakUsagesPage] = [:]
    @ObservationIgnored private var runs: [Int64: CodeSearchCancelling] = [:]
    /// Per workbench: the live search; an older one's callbacks are dropped.
    @ObservationIgnored private var generations: [Int64: Int] = [:]
    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    /// The workspace whose inspector state is read and written: its database
    /// path (`ChatView`'s `chat.lastWorkspace` precedent). AppState sets it
    /// in `initWorkbenches`, before any Files pane shows.
    @ObservationIgnored private(set) var workspace = ""

    /// Workspace → the workbench ids whose Files pane shows the inspector.
    static let shownInspectorsKey = "workbench.code.inspector.shown"
    /// Workspace → workbench id (as a string) → the inspector's tab.
    static let inspectorTabsKey = "workbench.code.inspector.tabs"

    init(
        defaults: UserDefaults = .standard,
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        self.defaults = defaults
        self.startSearch = startSearch
        self.beep = beep
        loadInspectorState()
    }

    /// Switches the inspector state to `workspace`'s.
    func useWorkspace(_ workspace: String) {
        guard workspace != self.workspace else { return }
        self.workspace = workspace
        loadInspectorState()
    }

    private func loadInspectorState() {
        let shown = defaults.dictionary(forKey: Self.shownInspectorsKey)?[workspace] as? [Int64] ?? []
        shownInspectors = Set(shown)
        let tabs = defaults.dictionary(forKey: Self.inspectorTabsKey)?[workspace] as? [String: String] ?? [:]
        inspectorTabs = tabs.reduce(into: [:]) { result, entry in
            if let id = Int64(entry.key), let tab = CodeInspectorTab(rawValue: entry.value) { result[id] = tab }
        }
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

    /// App quit (ruling R34): every Usages search is killed with its
    /// process group; the lists keep what they found.
    func stopUsagesSearches() {
        let running = runs
        runs.removeAll()
        for (workbenchID, run) in running {
            generations[workbenchID] = nil
            run.cancel()
            results[workbenchID]?.stop()
        }
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
        setInspectorShown(true, workbenchID: workbenchID)
        selectInspectorTab(.usages, workbenchID: workbenchID)
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
    /// Quickly's ↩), the cursor on the name; where the cursor was goes on
    /// Back (⌃⌘←), as for a definition jump (ruling R33).
    func openUsage(_ row: UsageRow, project: Workbench) async {
        navigation?.recordJumpFromCurrentLocation(project: project)
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
        saveShownInspectors()
    }

    func inspectorTab(workbenchID: Int64) -> CodeInspectorTab {
        inspectorTabs[workbenchID] ?? .usages
    }

    func selectInspectorTab(_ tab: CodeInspectorTab, workbenchID: Int64) {
        guard inspectorTabs[workbenchID] != tab else { return }
        inspectorTabs[workbenchID] = tab
        saveInspectorTabs()
    }

    /// A deleted workbench's inspector state goes with it, so stale entries
    /// do not pile up in UserDefaults (ids are never reused).
    func workbenchRemoved(_ workbenchID: Int64) {
        if shownInspectors.remove(workbenchID) != nil { saveShownInspectors() }
        if inspectorTabs.removeValue(forKey: workbenchID) != nil { saveInspectorTabs() }
    }

    private func saveShownInspectors() {
        var stored = defaults.dictionary(forKey: Self.shownInspectorsKey) ?? [:]
        stored[workspace] = shownInspectors.sorted()
        defaults.set(stored, forKey: Self.shownInspectorsKey)
    }

    private func saveInspectorTabs() {
        var stored = defaults.dictionary(forKey: Self.inspectorTabsKey) ?? [:]
        stored[workspace] = inspectorTabs.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value.rawValue }
        defaults.set(stored, forKey: Self.inspectorTabsKey)
    }
}

private struct WeakUsagesPage {
    weak var page: CodeUsagesPage?
}
