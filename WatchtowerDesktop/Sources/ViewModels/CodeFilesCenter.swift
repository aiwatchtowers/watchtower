import AppKit
import Foundation
import Observation
import WatchtowerCore

// The code viewer of a workbench: the FILES tree, the Files pane's tabs and
// the buffers behind them, file operations from the tree, and the folder's
// git status. Claude Code edits the same folder while the owner looks at
// it, so one FSEvents stream per folder (started the first time FILES or the
// Files pane is shown) refreshes the tree, the git marks and the open files
// — a clean buffer reloads silently, one with unsaved edits is never
// written over (`CodeFileBuffer`).

/// What the Files pane's editor page can be asked for: the edits typed in
/// it that it has not sent yet (its 300 ms debounce). Pulled before
/// anything that must not lose them — a close, a rename, leaving the app.
@MainActor
protocol CodeEditorBridge: AnyObject {
    /// nil when the page could not be asked (it is gone or broken).
    func takePending() async -> [CodeEditorPendingEdit]?
}

/// Where the Files pane puts the cursor once a file is on screen (Open
/// Quickly, go to definition, back/forward): sent to the page as
/// `reveal({id, line, col})` when the file is the one shown, then cleared.
/// Either way the keyboard moves into the editor.
struct CodeRevealRequest: Equatable {
    let path: String
    /// 1-based; nil = the cursor stays where the file had it.
    let line: Int?
    /// 1-based UTF-16 column.
    let col: Int
    /// Tells two requests for the same place apart.
    let serial: Int
}

struct CodeEditorPendingEdit: Equatable {
    /// `CodeFileBuffer.id`
    let id: String
    let text: String
    let base: Int
}

/// The trees, tabs, buffers and git status of every code root (a
/// workbench's folder or one of its worktrees, `CodeRoot`), kept for the
/// app's lifetime (owned by `WorkbenchesViewModel`, itself owned by `AppState`).
@MainActor
@Observable
final class CodeFilesCenter {
    /// A tab a close could not save, and why.
    struct Refusal: Equatable {
        let path: String
        let reason: String
    }

    /// A file with unsaved edits in a worktree that was removed (spec §7):
    /// its buffer never writes again; the owner copies or discards the text.
    struct OrphanedEdit: Identifiable {
        let root: CodeRoot
        let buffer: CodeFileBuffer
        var id: String { buffer.id }
    }

    enum OperationError: Error, LocalizedError, Equatable {
        case exists(String)
        case unsaved(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .exists(path): "“\(path)” already exists."
            case let .unsaved(path): "“\(path)” has edits that could not be saved — resolve them first."
            case let .failed(message): message
            }
        }
    }

    private(set) var tabsByRoot: [CodeRoot: CodeTabs] = [:]
    private(set) var gitByRoot: [CodeRoot: GitStatusSnapshot] = [:]
    /// git ran and failed; the last good marks stay shown.
    private(set) var gitErrors: [CodeRoot: String] = [:]
    /// The folder's FSEvents stream could not start: the view is not live.
    private(set) var watchErrors: [CodeRoot: String] = [:]
    /// The editor page failed (load error, crash); shown over the pane.
    var editorErrors: [CodeRoot: String] = [:]
    /// Per root: where the cursor goes once the file is on screen.
    private(set) var reveals: [CodeRoot: CodeRevealRequest] = [:]
    /// Per root: the editor's cursor as the page last reported it
    /// (`cursor`, at most 10 a second) — back/forward and the jump bar.
    private(set) var cursors: [CodeRoot: CodeNavLocation] = [:]
    /// Worktree roots whose folder went away (spec §7): the page falls back
    /// to the main folder. A root leaves the set when it shows again with
    /// its folder back, or its session's place resolves there again.
    private(set) var removedRoots: Set<CodeRoot> = []
    /// The unsaved edits of removed worktrees, oldest first — shown over the
    /// Files pane with Copy and Discard, kept for the app session.
    private(set) var orphanedEdits: [OrphanedEdit] = []
    @ObservationIgnored private var revealSerial = 0
    /// Per root, loaded on first use (gone files pruned).
    @ObservationIgnored private var recents: [CodeRoot: CodeRecentFiles] = [:]
    @ObservationIgnored private var trees: [CodeRoot: CodeFileTree] = [:]
    /// Per root and path: a workbench nested in another, or two worktrees,
    /// have their own buffer of a path (each guards its saves against the
    /// disk and writes only to the URL it was made with).
    @ObservationIgnored private var buffers: [BufferKey: CodeFileBuffer] = [:]
    /// `buffers`' keys by page id: an edit finds its buffer in O(1).
    @ObservationIgnored private var bufferKeys: [String: BufferKey] = [:]
    /// The buffers of removed worktrees by page id, locked, clean ones too,
    /// until Discard or the workbench is deleted (`forgetRemovedBuffers`) — text
    /// the page hands over late, however late, still lands (never on disk)
    /// and, once it makes a buffer dirty, joins `orphanedEdits`.
    @ObservationIgnored private var removedBuffers: [String: OrphanedEdit] = [:]
    @ObservationIgnored private var watchers: [CodeRoot: FolderWatcher] = [:]
    /// The roots shown at least once (their folder watched, git read).
    @ObservationIgnored private var watched: Set<CodeRoot> = []
    @ObservationIgnored private var bridges: [CodeRoot: WeakBridge] = [:]
    /// How many views (FILES, the Files pane) show each root: git runs
    /// only for one on screen, a hidden one is refreshed when it shows again.
    @ObservationIgnored private var showing: [CodeRoot: Int] = [:]
    @ObservationIgnored private var gitRunning: Set<CodeRoot> = []
    @ObservationIgnored private var gitPending: Set<CodeRoot> = []
    @ObservationIgnored private var gitLastRun: [CodeRoot: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let trash: (URL) throws -> Void
    @ObservationIgnored private let gitRead: (URL) async -> GitStatusRead
    @ObservationIgnored private let gitMinInterval: Duration
    /// Off in tests, which feed `handle` themselves.
    @ObservationIgnored private let watchesFolders: Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The symbol index (on `AppState`), told when a workbench shows and
    /// hides and fed this center's FSEvents batches — one stream per folder.
    @ObservationIgnored weak var codeIndex: CodeIndexCenter?
    /// Go to definition and history (on `AppState`); the editor page
    /// reports its `definition` requests there.
    @ObservationIgnored weak var navigation: CodeNavigationCenter?
    /// Usages and the Files pane's inspector (on `AppState`); the editor
    /// page reports its `usages` requests there.
    @ObservationIgnored weak var usages: CodeUsagesCenter?
    /// Code questions at the selection (on `AppState`); the editor page
    /// reports its `selection`, `scroll` and `askAI` there.
    @ObservationIgnored weak var questions: CodeQuestionCenter?
    /// A batch of a workbench folder touched its automation recipes
    /// (`touchesAutomationRecipes`): the workbench view model rescans them.
    @ObservationIgnored var onAutomationRecipesChanged: ((_ workbenchID: Int64) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        gitRead: @escaping (URL) async -> GitStatusRead = { await GitStatusSnapshot.read(folder: $0) },
        gitMinInterval: Duration = .seconds(1),
        watchesFolders: Bool = true
    ) {
        self.defaults = defaults
        self.trash = trash
        self.gitRead = gitRead
        self.gitMinInterval = gitMinInterval
        self.watchesFolders = watchesFolders
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.flushEverything() }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllGit() }
        })
    }

    // MARK: Tree and watching

    func tree(for root: CodeRoot) -> CodeFileTree {
        if let tree = trees[root] { return tree }
        let tree = CodeFileTree(root: root.folder)
        trees[root] = tree
        return tree
    }

    func git(for root: CodeRoot) -> GitStatusSnapshot {
        gitByRoot[root] ?? GitStatusSnapshot()
    }

    /// FILES or the Files pane came on screen: the root's folder is watched
    /// (once per root) and its git status read. Balanced by
    /// `stopShowing` when that view goes.
    func startWatching(_ root: CodeRoot) {
        if root.isMain { dropStaleMainRoots(of: root) }
        sweepRemovedWorktrees(workbenchID: root.workbenchID)
        // A worktree gone before it showed is not watched (nor indexed).
        guard root.isMain || CodeRootPolicy.directoryExists(root.folder) else { return }
        if removedRoots.contains(root) { removedRoots.remove(root) }
        showing[root, default: 0] += 1
        codeIndex?.markShown(root: root)
        let isNew = watched.insert(root).inserted
        // A worktree root is not watched while hidden: what changed
        // meanwhile is read again now.
        if isNew, !root.isMain { rescanRoot(root) }
        if watchesFolders, isNew || watchers[root] == nil {
            let watcher = FolderWatcher(root: root.folder, hidden: CodeFileTree.hiddenNames) { [weak self] batch in
                self?.handle(batch, root: root)
            }
            watchers[root] = watcher
            if watcher == nil {
                NSLog("CodeFilesCenter: no FSEvents stream for workbench %lld", root.workbenchID)
                watchErrors[root] = "Live updates are off for this folder — use Reload the tree."
            } else {
                watchErrors[root] = nil
            }
        }
        refreshGit(root)
    }

    /// The workbench moved to another folder: the old main root's stream
    /// and tree go (as `CodeIndexCenter.markShown` drops its index). Its
    /// buffers stay — one may still hold an edit to save.
    private func dropStaleMainRoots(of root: CodeRoot) {
        for stale in watched where stale.isMain && stale.workbenchID == root.workbenchID && stale != root {
            unwatchRoot(stale)
            dropRootViews(stale)
        }
    }

    /// The root's FSEvents stream and git scheduling go. A git run in
    /// flight finds the root unwatched after its await and lands nothing.
    private func unwatchRoot(_ root: CodeRoot) {
        watched.remove(root)
        watchers[root] = nil
        watchErrors[root] = nil
        showing[root] = nil
        gitPending.remove(root)
    }

    /// What the views showed of a root that is gone for good (a stale main
    /// root, a removed worktree): its tree and marks.
    private func dropRootViews(_ root: CodeRoot) {
        trees[root] = nil
        gitByRoot[root] = nil
        gitErrors[root] = nil
        gitLastRun[root] = nil
        reveals[root] = nil
        cursors[root] = nil
        editorErrors[root] = nil
    }

    /// Back on screen after an eviction: the tree and the buffers read the
    /// disk again (a clean buffer reloads, a dirty one turns to a conflict).
    private func rescanRoot(_ root: CodeRoot) {
        trees[root]?.reloadAll()
        for (key, buffer) in buffers where key.root == root {
            buffer.diskChanged()
        }
    }

    /// Balances `startWatching`. A worktree root nothing shows any more
    /// stops being watched (its tabs, buffers and autosave stay — a save
    /// still checks the disk first); the main root's stream stays.
    func stopShowing(_ root: CodeRoot) {
        let count = max(0, (showing[root] ?? 0) - 1)
        showing[root] = count
        codeIndex?.markHidden(root: root)
        if count == 0, !root.isMain { unwatchRoot(root) }
    }

    /// `startWatching` for as long as the calling task runs — a view's
    /// `.task(id:)`, cancelled when the view goes or its workbench changes.
    func show(_ root: CodeRoot) async {
        startWatching(root)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        stopShowing(root)
    }

    /// What FSEvents saw; internal for tests.
    func handle(_ batch: FolderWatcher.Batch, root: CodeRoot) {
        guard watched.contains(root) else { return }
        // Go indexes the workbench folder's recipes, not a worktree's copy.
        if root.isMain, Self.touchesAutomationRecipes(batch) { onAutomationRecipesChanged?(root.workbenchID) }
        if !root.isMain, batch.mustRescan || batch.paths.contains(""), !CodeRootPolicy.directoryExists(root.folder) {
            rootRemoved(root)
            return
        }
        codeIndex?.applyWatcherBatch(batch, root: root)
        let tree = trees[root]
        if batch.mustRescan {
            tree?.reloadAll()
            for (key, buffer) in buffers where key.root == root {
                buffer.diskChanged()
            }
        } else {
            if !batch.paths.isEmpty { tree?.refresh(directories: Set(batch.paths.map(Self.parent))) }
            for rel in batch.paths {
                buffers[BufferKey(root: root, path: rel)]?.diskChanged()
            }
        }
        if !batch.isEmpty { refreshGit(root) }
    }

    /// A change under `.watchtower/automations/` (the folder itself, or
    /// `.watchtower` created or removed), or events lost (anything may have
    /// changed).
    nonisolated static func touchesAutomationRecipes(_ batch: FolderWatcher.Batch) -> Bool {
        batch.mustRescan || batch.paths.contains {
            $0 == ".watchtower" || $0 == ".watchtower/automations" || $0.hasPrefix(".watchtower/automations/")
        }
    }

    private func refreshAllGit() {
        sweepRemovedWorktrees()
        watched.filter { (showing[$0] ?? 0) > 0 }.forEach(refreshGit)
    }

    /// One `git status` at a time per root, at most one per
    /// `gitMinInterval`; a change during a run queues exactly one more. A
    /// failed run keeps the last good marks and says why.
    private func refreshGit(_ root: CodeRoot) {
        guard watched.contains(root), (showing[root] ?? 0) > 0 else { return }
        guard !gitRunning.contains(root) else {
            gitPending.insert(root)
            return
        }
        gitRunning.insert(root)
        let wait = gitLastRun[root].map { gitMinInterval - (ContinuousClock.now - $0) } ?? .zero
        Task { @MainActor in
            if wait > .zero { try? await Task.sleep(for: wait) }
            let read = await gitRead(root.folder)
            gitRunning.remove(root)
            // Unwatched meanwhile (hidden worktree, stale or removed root):
            // nothing lands; showing it again reads git afresh.
            guard watched.contains(root) else {
                gitPending.remove(root)
                return
            }
            gitLastRun[root] = .now
            switch read {
            case .noRepository:
                gitByRoot[root] = nil
                gitErrors[root] = nil
            case let .snapshot(snapshot):
                if gitByRoot[root] != snapshot { gitByRoot[root] = snapshot }
                gitErrors[root] = nil
            case let .failed(message):
                NSLog("CodeFilesCenter: git status failed for workbench %lld: %@", root.workbenchID, message)
                gitErrors[root] = message
            }
            if gitPending.remove(root) != nil { refreshGit(root) }
        }
    }

    // MARK: Tabs

    func tabs(for root: CodeRoot) -> CodeTabs {
        if let tabs = tabsByRoot[root] { return tabs }
        let tabs = restoredTabs(root)
        // Deferred: this runs while a view body reads it.
        Task { @MainActor in if self.tabsByRoot[root] == nil { self.tabsByRoot[root] = tabs } }
        return tabs
    }

    private func restoredTabs(_ root: CodeRoot) -> CodeTabs {
        let key = CodeTabs.key(root: root)
        guard let data = defaults.data(forKey: key) else { return CodeTabs() }
        do {
            var tabs = try JSONDecoder().decode(CodeTabs.self, from: data)
            tabs.prune { FileManager.default.fileExists(atPath: root.folder.appendingPathComponent($0).path) }
            return tabs
        } catch {
            // Kept aside rather than overwritten by the next change.
            NSLog("CodeFilesCenter: unreadable saved tabs for workbench %lld: %@", root.workbenchID, String(describing: error))
            defaults.set(data, forKey: key + ".unreadable")
            defaults.removeObject(forKey: key)
            return CodeTabs()
        }
    }

    /// Opens `path` in a tab. A preview open that replaces the preview tab
    /// lets that tab's buffer go when nothing in it is unsaved (callers pull
    /// the page's pending edits first — `WorkbenchesViewModel.openFile` —
    /// and a dirty preview tab was already kept by its first edit).
    func open(_ path: String, root: CodeRoot, preview: Bool) {
        let before = tabsByRoot[root] ?? restoredTabs(root)
        mutateTabs(root) { $0.open(path, preview: preview) }
        recordRecent(path, root: root)
        let after = tabsByRoot[root] ?? CodeTabs()
        for gone in before.paths where !after.contains(gone) {
            if let buffer = existingBuffer(root, gone), !buffer.isDirty, buffer.problem == nil {
                forgetBuffer(root, gone)
            }
        }
    }

    func activate(_ path: String, root: CodeRoot) {
        mutateTabs(root) { $0.activate(path) }
        if tabsByRoot[root]?.active == path { recordRecent(path, root: root) }
    }

    func pin(_ path: String, root: CodeRoot) {
        mutateTabs(root) { $0.pin(path) }
    }

    func move(_ path: String, before target: String?, root: CodeRoot) {
        mutateTabs(root) { $0.move(path, before: target) }
    }

    /// Closes the tabs `paths` after pulling the page's unsent edits and
    /// saving what each still holds. A tab whose save is refused stays open;
    /// the refusals say why (a conflict, a deletion, a write error).
    @discardableResult
    func close(_ paths: [String], root: CodeRoot) async -> [Refusal] {
        await pullPending(root)
        var refusals: [Refusal] = []
        for path in paths {
            if let buffer = existingBuffer(root, path), buffer.isDirty, !buffer.saveNow() {
                refusals.append(Refusal(path: path, reason: buffer.unsavedReason ?? "Could not save."))
                continue
            }
            mutateTabs(root) { $0.close(path) }
            forgetBuffer(root, path)
        }
        return refusals
    }

    /// Closes `paths` dropping their unsaved edits (the refusal dialog's
    /// Close and Discard).
    func discardAndClose(_ paths: [String], root: CodeRoot) {
        for path in paths {
            mutateTabs(root) { $0.close(path) }
            forgetBuffer(root, path)
        }
    }

    private func mutateTabs(_ root: CodeRoot, _ change: (inout CodeTabs) -> Void) {
        var tabs = tabsByRoot[root] ?? restoredTabs(root)
        change(&tabs)
        tabsByRoot[root] = tabs
        do {
            defaults.set(try JSONEncoder().encode(tabs), forKey: CodeTabs.key(root: root))
        } catch {
            NSLog("CodeFilesCenter: could not save the tabs of workbench %lld: %@", root.workbenchID, String(describing: error))
        }
    }

    // MARK: Recently opened and reveal

    /// The files the Files pane opened most recently, newest first (the
    /// last 50) — Open Quickly's "recently opened" boost (ruling R22).
    /// Files gone from disk are dropped when the list is first read.
    func recentFiles(for root: CodeRoot) -> [String] {
        recentList(root).paths
    }

    private func recentList(_ root: CodeRoot) -> CodeRecentFiles {
        if let list = recents[root] { return list }
        var list = CodeRecentFiles(paths: defaults.stringArray(forKey: CodeRecentFiles.key(root: root)) ?? [])
        list.prune { FileManager.default.fileExists(atPath: root.folder.appendingPathComponent($0).path) }
        recents[root] = list
        return list
    }

    private func recordRecent(_ path: String, root: CodeRoot) {
        var list = recentList(root)
        list.record(path)
        recents[root] = list
        defaults.set(list.paths, forKey: CodeRecentFiles.key(root: root))
    }

    /// The cursor goes to `line`:`col` of `path` (nil line: where it was)
    /// and the keyboard into the editor once the Files pane shows it
    /// (replacing any request not yet carried out).
    func requestReveal(_ path: String, line: Int?, col: Int?, root: CodeRoot) {
        revealSerial += 1
        reveals[root] = CodeRevealRequest(
            path: path, line: line.map { max(1, $0) }, col: max(1, col ?? 1), serial: revealSerial
        )
    }

    /// The page's `cursor` message.
    func cursorMoved(_ location: CodeNavLocation, root: CodeRoot) {
        if cursors[root] != location { cursors[root] = location }
    }

    /// The page was told: the request is done (a newer one stays).
    func revealSent(_ request: CodeRevealRequest, root: CodeRoot) {
        if reveals[root] == request { reveals[root] = nil }
    }

    // MARK: Buffers

    func buffer(for root: CodeRoot, relPath: String) -> CodeFileBuffer {
        let key = BufferKey(root: root, path: relPath)
        if let buffer = buffers[key] { return buffer }
        let buffer = CodeFileBuffer(
            url: root.folder.appendingPathComponent(relPath), relPath: relPath,
            worktreeFolder: root.isMain ? nil : root.folder
        )
        // A save that finds the worktree gone (removed while hidden) has
        // locked the buffer; the whole root follows.
        if !root.isMain { buffer.onWorktreeMissing = { [weak self] in self?.rootRemoved(root) } }
        storeBuffer(buffer, at: key)
        return buffer
    }

    private func storeBuffer(_ buffer: CodeFileBuffer, at key: BufferKey) {
        buffers[key] = buffer
        bufferKeys[buffer.id] = key
    }

    @discardableResult
    private func dropBuffer(at key: BufferKey) -> CodeFileBuffer? {
        guard let buffer = buffers.removeValue(forKey: key) else { return nil }
        bufferKeys[buffer.id] = nil
        return buffer
    }

    /// The buffer of `path` if one is loaded — also after a preview tab was
    /// replaced, so an edit the page sends late still lands.
    func existingBuffer(_ root: CodeRoot, _ path: String) -> CodeFileBuffer? {
        buffers[BufferKey(root: root, path: path)]
    }

    /// Any loaded buffer by its page id — a removed worktree's included, so
    /// an edit the page hands over late still reaches it (never the disk).
    func buffer(id: String) -> CodeFileBuffer? {
        bufferKeys[id].flatMap { buffers[$0] } ?? removedBuffers[id]?.buffer
    }

    /// The root a loaded buffer belongs to (nil for a removed worktree's).
    private func ownerRoot(of buffer: CodeFileBuffer) -> CodeRoot? {
        guard let key = bufferKeys[buffer.id], buffers[key] === buffer else { return nil }
        return key.root
    }

    /// The loaded buffers of `root` at `path` or under it (a folder) —
    /// never another root's, whatever the paths.
    func buffers(under path: String, root: CodeRoot) -> [CodeFileBuffer] {
        buffers.compactMap { key, buffer in
            key.root == root && (key.path == path || key.path.hasPrefix(path + "/")) ? buffer : nil
        }
    }

    /// The page ids of the buffers open in tabs of the workbench's other
    /// roots — the models the editor page keeps while another root shows.
    func openBufferIDs(workbenchID: Int64, except root: CodeRoot) -> Set<String> {
        var ids: Set<String> = []
        for (other, tabs) in tabsByRoot where other.workbenchID == workbenchID && other != root {
            for path in tabs.paths {
                if let buffer = buffers[BufferKey(root: other, path: path)] { ids.insert(buffer.id) }
            }
        }
        return ids
    }

    private func forgetBuffer(_ root: CodeRoot, _ path: String) {
        dropBuffer(at: BufferKey(root: root, path: path))?.cancelAutosave()
    }

    // MARK: Flushing

    func register(_ bridge: CodeEditorBridge, for root: CodeRoot) {
        bridges[root] = WeakBridge(bridge: bridge, root: root)
    }

    func unregister(_ bridge: CodeEditorBridge, for root: CodeRoot) {
        if bridges[root]?.bridge === bridge { bridges[root] = nil }
    }

    /// The page went: its bridge goes from whatever root it answers for
    /// now (a root switch moves it after the page already follows).
    func unregisterBridge(_ bridge: CodeEditorBridge) {
        for (root, entry) in bridges where entry.bridge === bridge || entry.bridge == nil {
            bridges[root] = nil
        }
    }

    /// The page's unsent edits of `root` go into their buffers. A page
    /// that cannot be asked is logged and shown — its last 300 ms of typing
    /// may be lost, and the owner should know.
    func pullPending(_ root: CodeRoot) async {
        guard let bridge = bridges[root]?.bridge else { return }
        guard let edits = await bridge.takePending() else {
            NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its unsent edits", root.workbenchID)
            editorErrors[root] = "The editor did not answer; edits typed in the last moment may not be saved."
            return
        }
        if editorErrors[root]?.hasPrefix("The editor did not answer") == true { editorErrors[root] = nil }
        apply(edits, now: false)
    }

    // MARK: Switching roots

    /// The page's active root moved from `previous` to `root` (one
    /// workbench, spec §6.3): the editor page's unsent edits go into their
    /// buffers — the old root's — and are saved there before anything else,
    /// and the page's bridge now answers for `root`. The old root's tabs,
    /// buffers and autosave stay (each worktree keeps its set). A previous
    /// worktree whose folder is gone has its buffers locked before the page
    /// is asked — what it hands over is kept, never written — and every
    /// worktree of the workbench whose folder went (also while hidden) is
    /// then `rootRemoved`.
    func switchRoot(to root: CodeRoot, from previous: CodeRoot) async {
        guard root != previous, root.workbenchID == previous.workbenchID else { return }
        if !previous.isMain, !CodeRootPolicy.directoryExists(previous.folder) {
            for (key, buffer) in buffers where key.root == previous {
                buffer.lockWrites()
            }
        }
        await handOverPending(from: previous, to: root)
        sweepRemovedWorktrees(workbenchID: root.workbenchID)
    }

    /// The page's bridge moves from `previous` to `root`; its unsent edits
    /// go into their buffers and are saved at once (unless locked). A page
    /// that does not answer within `pendingTimeout` says so over the pane.
    private func handOverPending(from previous: CodeRoot, to root: CodeRoot) async {
        guard let bridge = bridges[previous]?.bridge else { return }
        bridges[previous] = nil
        if bridges[root]?.bridge == nil { bridges[root] = WeakBridge(bridge: bridge, root: root) }
        guard let edits = await takePending(bridge) else {
            NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its unsent edits on a root switch", root.workbenchID)
            editorErrors[root] = "The editor did not answer; edits typed in the last moment may not be saved."
            return
        }
        apply(edits, now: true)
    }

    /// Every worktree root (of `workbenchID`, or of every workbench) that
    /// holds buffers, tabs or a watch and whose folder is gone is
    /// `rootRemoved` — also one removed while nothing watched it, so its
    /// edits are locked before anything could write them.
    func sweepRemovedWorktrees(workbenchID: Int64? = nil) {
        let held = Set(buffers.keys.map(\.root)).union(tabsByRoot.keys).union(watched)
        let gone = held.filter { root in
            !root.isMain && (workbenchID == nil || root.workbenchID == workbenchID)
                && !CodeRootPolicy.directoryExists(root.folder)
        }
        gone.forEach(rootRemoved)
    }

    /// The worktree of `root` was removed (spec §7): it is never written
    /// again. The tabs and their saved key, the recents, the tree and the
    /// marks go; every buffer is locked and kept (late page text still
    /// lands), those with unsaved edits listed in `orphanedEdits` for Copy
    /// or Discard. The main root is never "removed".
    func rootRemoved(_ root: CodeRoot) {
        guard !root.isMain else { return }
        removedRoots.insert(root)
        for key in buffers.keys where key.root == root {
            guard let buffer = dropBuffer(at: key) else { continue }
            buffer.lockWrites()
            let record = OrphanedEdit(root: root, buffer: buffer)
            removedBuffers[buffer.id] = record
            if buffer.isDirty { orphanedEdits.append(record) }
        }
        tabsByRoot[root] = nil
        defaults.removeObject(forKey: CodeTabs.key(root: root))
        recents[root] = nil
        defaults.removeObject(forKey: CodeRecentFiles.key(root: root))
        unwatchRoot(root)
        dropRootViews(root)
        navigation?.codeRootRemoved(root)
        usages?.codeRootRemoved(root)
        questions?.codeRootRemoved(root)
    }

    /// The workbench was deleted: its removed worktrees' locked buffers and
    /// unsaved edits go (nothing can hand text over for them any more).
    func forgetRemovedBuffers(workbenchID: Int64) {
        orphanedEdits.removeAll { $0.root.workbenchID == workbenchID }
        removedBuffers = removedBuffers.filter { $0.value.root.workbenchID != workbenchID }
    }

    /// The session's place resolves to a live worktree at the path of a
    /// removed one: a worktree recreated there shows again. The old locked
    /// buffers stay locked in the banner; the new root gets fresh ones.
    func worktreeCameBack(_ root: CodeRoot) {
        guard !root.isMain, removedRoots.contains(root), CodeRootPolicy.directoryExists(root.folder) else { return }
        removedRoots.remove(root)
    }

    /// Whether `root`'s worktree was removed and has not come back.
    func isRemoved(_ root: CodeRoot) -> Bool {
        removedRoots.contains(root) && !CodeRootPolicy.directoryExists(root.folder)
    }

    /// The banner's Discard: the edits are dropped (nothing was written).
    func discardOrphanedEdit(id: String) {
        orphanedEdits.removeAll { $0.id == id }
        removedBuffers[id] = nil
    }

    /// The removed worktrees' unsaved edits a workbench's page lists.
    func orphanedEdits(workbenchID: Int64) -> [OrphanedEdit] {
        orphanedEdits.filter { $0.root.workbenchID == workbenchID }
    }

    /// Edits the page handed over (a pull, the pane going away), each into
    /// its own buffer, whatever root the page shows now.
    func apply(_ edits: [CodeEditorPendingEdit], now: Bool) {
        for edit in edits {
            guard let buffer = buffer(id: edit.id) else {
                NSLog("CodeFilesCenter: an edit for a buffer no longer open was dropped")
                continue
            }
            edited(buffer, text: edit.text, base: edit.base, now: now)
            keepLateOrphan(edit.id)
        }
    }

    /// Text handed over after its worktree was removed made a clean,
    /// locked buffer dirty: it joins the banner's Copy/Discard list.
    private func keepLateOrphan(_ id: String) {
        guard let record = removedBuffers[id], record.buffer.isDirty,
              !orphanedEdits.contains(where: { $0.id == id }) else { return }
        orphanedEdits.append(record)
    }

    /// One edit from the page: into its buffer, and the first edit keeps a
    /// preview tab — of the buffer's own root (the page holds the models of
    /// every root it showed, so the root on screen says nothing).
    /// An edit saved at once (a flush) keeps it too.
    func edited(_ buffer: CodeFileBuffer, text: String, base: Int, now: Bool = false, explicit: Bool = false) {
        let changesTheFile = buffer.state == .loaded && text != buffer.diskText
        buffer.edited(text, base: base, now: now, explicit: explicit)
        guard changesTheFile, let owner = ownerRoot(of: buffer) else { return }
        let tabs = tabsByRoot[owner] ?? restoredTabs(owner)
        if tabs.tabs.first(where: { $0.path == buffer.relPath })?.isPreview == true {
            pin(buffer.relPath, root: owner)
        }
    }

    /// The app lost focus: everything typed goes to disk now.
    func flushEverything() async {
        for entry in bridges.values {
            guard let bridge = entry.bridge else { continue }
            // Bounded: a page that does not answer cannot hold the flush.
            guard let edits = await takePending(bridge) else {
                NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its unsent edits on a flush", entry.root.workbenchID)
                continue
            }
            // Through `apply`: the first edit keeps a preview tab here too.
            apply(edits, now: false)
        }
        sweepRemovedWorktrees()
        flushAll()
    }

    /// What `saveEdits` left on disk before a branch switch.
    enum WorkTreeSave: Equatable {
        /// Every edit under the work tree is on disk.
        case saved
        /// This buffer's edits could not be written (a conflict, a deleted or
        /// unreadable file, a write error).
        case unsaved(String)
        /// An editor page did not hand over its unsent edits (it failed, or
        /// did not answer within `pendingTimeout`).
        case editorSilent
    }

    /// How long a branch switch waits for the editor page's unsent edits.
    /// Internal for tests.
    @ObservationIgnored var pendingTimeout: Duration = .seconds(2)

    /// A branch switch is about to rewrite `workTree` (the work tree of
    /// `root`): the unsent edits of every root the switch covers are pulled
    /// and its buffers in the work tree saved, so the switch's dirty check
    /// sees them on disk. One rule for both (`BranchSwitchScope`): a buffer
    /// saved here always had its page's unsent edits pulled first. Another
    /// worktree's root is not this switch's (board #565) — not even one
    /// nested in the main folder (`.claude/worktrees/<name>`), which git
    /// keeps apart. Unlike a close or a rename, a page that does not answer
    /// stops the switch: the files would be swapped under edits nobody has.
    func saveEdits(root: CodeRoot, workTree: String) async -> WorkTreeSave {
        let others = Set(buffers.keys.map(\.root)).union(bridges.keys).filter { !$0.isMain && $0 != root }
        let scope = BranchSwitchScope(root: root, workTree: workTree, otherWorktrees: others.map(\.folder.path))
        var silent = false
        for entry in bridges.values where scope.pullsEdits(of: entry.root) {
            guard let bridge = entry.bridge else { continue }
            guard let edits = await takePending(bridge) else {
                NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its edits before a branch switch", entry.root.workbenchID)
                silent = true
                continue
            }
            apply(edits, now: false)
        }
        if silent { return .editorSilent }
        let affected = buffers
            .filter { key, buffer in scope.savesBuffer(of: key.root, at: buffer.url.path) }
            .sorted { $0.key.path < $1.key.path }
        var unsaved: String?
        for (_, buffer) in affected where buffer.isDirty && !buffer.saveNow() {
            NSLog("CodeFilesCenter: %@ not saved before a branch switch: %@", buffer.relPath, buffer.unsavedReason ?? "")
            unsaved = unsaved ?? buffer.relPath
        }
        return unsaved.map(WorkTreeSave.unsaved) ?? .saved
    }

    /// The page's unsent edits, nil when it failed or did not answer within
    /// `pendingTimeout`. Edits handed over after that still go into their
    /// buffers — the page has let go of them.
    private func takePending(_ bridge: CodeEditorBridge) async -> [CodeEditorPendingEdit]? {
        let wait = PendingWait()
        let limit = pendingTimeout
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                if wait.finish() { continuation.resume(returning: nil) }
            }
            Task { @MainActor in
                let edits = await bridge.takePending()
                timer.cancel()
                if wait.finish() {
                    continuation.resume(returning: edits)
                } else if let edits {
                    self.apply(edits, now: false)
                }
            }
        }
    }

    /// Saves every buffer with unsaved edits (also on quit, where the page
    /// can no longer be asked).
    func flushAll() {
        for buffer in buffers.values where buffer.isDirty && !buffer.saveNow() {
            NSLog("CodeFilesCenter: %@ not saved: %@", buffer.relPath, buffer.unsavedReason ?? "")
        }
    }

    // MARK: File operations (the FILES tree)

    /// Creates an empty file (and any missing folders) and opens it in a
    /// kept tab. Returns its path.
    @discardableResult
    func createFile(_ input: String, in directory: String, root: CodeRoot) throws -> String {
        let path = try CodeFileName.resolve(input, in: directory)
        try requireLiveFolder(root)
        let url = root.folder.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw OperationError.exists(path) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        revealInTree(path, root: root)
        open(path, root: root, preview: false)
        return path
    }

    @discardableResult
    func createFolder(_ input: String, in directory: String, root: CodeRoot) throws -> String {
        let path = try CodeFileName.resolve(input, in: directory)
        try requireLiveFolder(root)
        let url = root.folder.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw OperationError.exists(path) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        revealInTree(path, root: root)
        tree(for: root).expand(path)
        return path
    }

    /// Renames or moves `path` (a file or a folder) to `input`, a name or a
    /// path relative to its folder. Unsaved edits under it are saved first;
    /// its tabs and buffers follow, keeping undo. Returns the new path.
    @discardableResult
    func rename(_ path: String, to input: String, root: CodeRoot) async throws -> String {
        let newPath = try CodeFileName.resolve(input, in: Self.parent(path))
        guard newPath != path else { return path }
        guard !newPath.hasPrefix(path + "/") else { throw OperationError.failed("A folder cannot move into itself.") }
        try requireLiveFolder(root)
        await pullPending(root)
        // The page was asked: the worktree may have gone meanwhile.
        try requireLiveFolder(root)
        let folder = root.folder
        let affected = buffers(under: path, root: root)
        for buffer in affected where buffer.isDirty && !buffer.saveNow() {
            throw OperationError.unsaved(buffer.relPath)
        }
        let from = folder.appendingPathComponent(path)
        let to = folder.appendingPathComponent(newPath)
        let caseOnly = path.lowercased() == newPath.lowercased()
        // An open tab or buffer at the target (a file deleted on disk but
        // still open) would be shadowed by the moved one.
        let tabs = tabsByRoot[root] ?? restoredTabs(root)
        let occupied = tabs.paths.contains { $0 == newPath || $0.hasPrefix(newPath + "/") }
            || !buffers(under: newPath, root: root).isEmpty
        if !caseOnly, occupied || FileManager.default.fileExists(atPath: to.path) { throw OperationError.exists(newPath) }
        if caseOnly, Self.exactNameExists(to) { throw OperationError.exists(newPath) }
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if caseOnly {
                // A case-insensitive volume sees the target as the source.
                let step = from.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                try FileManager.default.moveItem(at: from, to: step)
                do {
                    try FileManager.default.moveItem(at: step, to: to)
                } catch {
                    do {
                        try FileManager.default.moveItem(at: step, to: from)
                    } catch {
                        let name = step.lastPathComponent
                        throw OperationError.failed("The rename stopped halfway: the entry is now named “\(name)” in the same folder.")
                    }
                    throw error
                }
            } else {
                try FileManager.default.moveItem(at: from, to: to)
            }
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        for buffer in affected {
            let moved = newPath + buffer.relPath.dropFirst(path.count)
            dropBuffer(at: BufferKey(root: root, path: buffer.relPath))
            buffer.moved(to: folder.appendingPathComponent(moved), relPath: moved)
            storeBuffer(buffer, at: BufferKey(root: root, path: moved))
        }
        mutateTabs(root) { $0.rename(path, to: newPath) }
        let tree = tree(for: root)
        tree.refresh(directories: [Self.parent(path), Self.parent(newPath)])
        revealInTree(newPath, root: root)
        return newPath
    }

    /// A tree operation never runs in a removed worktree nor in a folder
    /// that is gone: its `createDirectory(withIntermediateDirectories:)`
    /// would recreate the folder (PROJ-03). A worktree found gone is
    /// `rootRemoved` on the way.
    private func requireLiveFolder(_ root: CodeRoot) throws {
        let exists = CodeRootPolicy.directoryExists(root.folder)
        guard removedRoots.contains(root) || !exists else { return }
        if !root.isMain, !exists { rootRemoved(root) }
        let what = root.isMain ? "The workbench folder" : "The worktree \(root.worktreeFolderName)"
        throw OperationError.failed("\(what) is gone — nothing is created or moved there.")
    }

    /// Whether `url`'s exact name (case included) is already an entry of its
    /// folder — on a case-sensitive volume `makefile` beside `Makefile`.
    private static func exactNameExists(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.contains(url.lastPathComponent)
    }

    /// Moves `path` (a file or a folder) to the macOS Trash; its tabs close.
    /// Unsaved edits under it are saved first, so the Trash holds them; one
    /// that cannot be saved refuses the move.
    func moveToTrash(_ path: String, root: CodeRoot) async throws {
        await pullPending(root)
        let gone = buffers(under: path, root: root)
        for buffer in gone where buffer.isDirty && !buffer.saveNow() {
            throw OperationError.unsaved(buffer.relPath)
        }
        do {
            try trash(root.folder.appendingPathComponent(path))
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        for buffer in gone {
            buffer.cancelAutosave()
            dropBuffer(at: BufferKey(root: root, path: buffer.relPath))
        }
        mutateTabs(root) { $0.closeTree(path) }
        tree(for: root).refresh(directories: [Self.parent(path)])
    }

    /// How many files a folder holds, for the Trash confirmation.
    /// Off the main thread; the folders the tree hides are not counted.
    nonisolated static func fileCount(at url: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
            if CodeFileTree.hiddenNames.contains(item.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }

    private func revealInTree(_ path: String, root: CodeRoot) {
        let tree = tree(for: root)
        let parent = Self.parent(path)
        tree.expand(parent)
        tree.refresh(directories: [parent])
    }

    nonisolated static func parent(_ relPath: String) -> String {
        let parent = (relPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

private struct BufferKey: Hashable {
    let root: CodeRoot
    let path: String
}

/// Which of `takePending`'s two tasks answered first.
@MainActor
private final class PendingWait {
    private var done = false

    /// true for the first caller only.
    func finish() -> Bool {
        defer { done = true }
        return !done
    }
}

private struct WeakBridge {
    weak var bridge: CodeEditorBridge?
    let root: CodeRoot
}
