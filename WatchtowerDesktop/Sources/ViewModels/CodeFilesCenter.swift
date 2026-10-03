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

struct CodeEditorPendingEdit: Equatable {
    /// `CodeFileBuffer.id`
    let id: String
    let text: String
    let base: Int
}

/// The trees, tabs, buffers and git status of every workbench, kept for the
/// app's lifetime (owned by `WorkbenchesViewModel`, itself owned by `AppState`).
@MainActor
@Observable
final class CodeFilesCenter {
    /// A tab a close could not save, and why.
    struct Refusal: Equatable {
        let path: String
        let reason: String
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

    private(set) var tabsByWorkbench: [Int64: CodeTabs] = [:]
    private(set) var gitByWorkbench: [Int64: GitStatusSnapshot] = [:]
    /// git ran and failed; the last good marks stay shown.
    private(set) var gitErrors: [Int64: String] = [:]
    /// The folder's FSEvents stream could not start: the view is not live.
    private(set) var watchErrors: [Int64: String] = [:]
    /// The editor page failed (load error, crash); shown over the pane.
    var editorErrors: [Int64: String] = [:]
    @ObservationIgnored private var trees: [Int64: CodeFileTree] = [:]
    /// Per workbench and path: a workbench nested in another has its own
    /// buffer of a shared file (both guard their saves against the disk).
    @ObservationIgnored private var buffers: [BufferKey: CodeFileBuffer] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]
    @ObservationIgnored private var folders: [Int64: URL] = [:]
    @ObservationIgnored private var bridges: [Int64: WeakBridge] = [:]
    /// How many views (FILES, the Files pane) show each workbench: git runs
    /// only for one on screen, a hidden one is refreshed when it shows again.
    @ObservationIgnored private var showing: [Int64: Int] = [:]
    @ObservationIgnored private var gitRunning: Set<Int64> = []
    @ObservationIgnored private var gitPending: Set<Int64> = []
    @ObservationIgnored private var gitLastRun: [Int64: ContinuousClock.Instant] = [:]
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

    func tree(for project: Workbench) -> CodeFileTree {
        if let tree = trees[project.id], tree.root == project.folderURL { return tree }
        let tree = CodeFileTree(root: project.folderURL)
        trees[project.id] = tree
        return tree
    }

    func git(for project: Workbench) -> GitStatusSnapshot {
        gitByWorkbench[project.id] ?? GitStatusSnapshot()
    }

    /// FILES or the Files pane came on screen: the folder is watched (once
    /// per workbench and folder) and its git status read. Balanced by
    /// `stopShowing` when that view goes.
    func startWatching(_ project: Workbench) {
        showing[project.id, default: 0] += 1
        codeIndex?.markShown(workbenchID: project.id, folder: project.folderURL)
        let isNew = folders[project.id] != project.folderURL
        folders[project.id] = project.folderURL
        if watchesFolders, isNew || watchers[project.id] == nil {
            let projectID = project.id
            let watcher = FolderWatcher(root: project.folderURL, hidden: CodeFileTree.hiddenNames) { [weak self] batch in
                self?.handle(batch, projectID: projectID)
            }
            watchers[projectID] = watcher
            if watcher == nil {
                NSLog("CodeFilesCenter: no FSEvents stream for workbench %lld", projectID)
                watchErrors[projectID] = "Live updates are off for this folder — use Reload the tree."
            } else {
                watchErrors[projectID] = nil
            }
        }
        refreshGit(project.id)
    }

    func stopShowing(_ project: Workbench) {
        showing[project.id] = max(0, (showing[project.id] ?? 0) - 1)
        codeIndex?.markHidden(workbenchID: project.id)
    }

    /// `startWatching` for as long as the calling task runs — a view's
    /// `.task(id:)`, cancelled when the view goes or its workbench changes.
    func show(_ project: Workbench) async {
        startWatching(project)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        stopShowing(project)
    }

    /// What FSEvents saw; internal for tests.
    func handle(_ batch: FolderWatcher.Batch, projectID: Int64) {
        guard folders[projectID] != nil else { return }
        codeIndex?.applyWatcherBatch(batch, workbenchID: projectID)
        let tree = trees[projectID]
        if batch.mustRescan {
            tree?.reloadAll()
            for (key, buffer) in buffers where key.workbench == projectID {
                buffer.diskChanged()
            }
        } else {
            if !batch.paths.isEmpty { tree?.refresh(directories: Set(batch.paths.map(Self.parent))) }
            for rel in batch.paths {
                buffers[BufferKey(workbench: projectID, path: rel)]?.diskChanged()
            }
        }
        if !batch.isEmpty { refreshGit(projectID) }
    }

    private func refreshAllGit() {
        folders.keys.filter { (showing[$0] ?? 0) > 0 }.forEach(refreshGit)
    }

    /// One `git status` at a time per workbench, at most one per
    /// `gitMinInterval`; a change during a run queues exactly one more. A
    /// failed run keeps the last good marks and says why.
    private func refreshGit(_ projectID: Int64) {
        guard let folder = folders[projectID], (showing[projectID] ?? 0) > 0 else { return }
        guard !gitRunning.contains(projectID) else {
            gitPending.insert(projectID)
            return
        }
        gitRunning.insert(projectID)
        let wait = gitLastRun[projectID].map { gitMinInterval - (ContinuousClock.now - $0) } ?? .zero
        Task { @MainActor in
            if wait > .zero { try? await Task.sleep(for: wait) }
            let read = await gitRead(folder)
            gitLastRun[projectID] = .now
            gitRunning.remove(projectID)
            switch read {
            case .noRepository:
                gitByWorkbench[projectID] = nil
                gitErrors[projectID] = nil
            case let .snapshot(snapshot):
                if gitByWorkbench[projectID] != snapshot { gitByWorkbench[projectID] = snapshot }
                gitErrors[projectID] = nil
            case let .failed(message):
                NSLog("CodeFilesCenter: git status failed for workbench %lld: %@", projectID, message)
                gitErrors[projectID] = message
            }
            if gitPending.remove(projectID) != nil { refreshGit(projectID) }
        }
    }

    // MARK: Tabs

    func tabs(for project: Workbench) -> CodeTabs {
        if let tabs = tabsByWorkbench[project.id] { return tabs }
        let tabs = restoredTabs(project)
        // Deferred: this runs while a view body reads it.
        let id = project.id
        Task { @MainActor in if self.tabsByWorkbench[id] == nil { self.tabsByWorkbench[id] = tabs } }
        return tabs
    }

    private func restoredTabs(_ project: Workbench) -> CodeTabs {
        let key = CodeTabs.key(workbenchID: project.id)
        guard let data = defaults.data(forKey: key) else { return CodeTabs() }
        do {
            var tabs = try JSONDecoder().decode(CodeTabs.self, from: data)
            tabs.prune { FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path) }
            return tabs
        } catch {
            // Kept aside rather than overwritten by the next change.
            NSLog("CodeFilesCenter: unreadable saved tabs for workbench %lld: %@", project.id, String(describing: error))
            defaults.set(data, forKey: key + ".unreadable")
            defaults.removeObject(forKey: key)
            return CodeTabs()
        }
    }

    /// Opens `path` in a tab. A preview open that replaces the preview tab
    /// lets that tab's buffer go when nothing in it is unsaved (callers pull
    /// the page's pending edits first — `WorkbenchesViewModel.openFile` —
    /// and a dirty preview tab was already kept by its first edit).
    func open(_ path: String, project: Workbench, preview: Bool) {
        let before = tabsByWorkbench[project.id] ?? restoredTabs(project)
        mutateTabs(project) { $0.open(path, preview: preview) }
        let after = tabsByWorkbench[project.id] ?? CodeTabs()
        for gone in before.paths where !after.contains(gone) {
            if let buffer = existingBuffer(project, gone), !buffer.isDirty, buffer.problem == nil {
                forgetBuffer(project, gone)
            }
        }
    }

    func activate(_ path: String, project: Workbench) {
        mutateTabs(project) { $0.activate(path) }
    }

    func pin(_ path: String, project: Workbench) {
        mutateTabs(project) { $0.pin(path) }
    }

    func move(_ path: String, before target: String?, project: Workbench) {
        mutateTabs(project) { $0.move(path, before: target) }
    }

    /// Closes the tabs `paths` after pulling the page's unsent edits and
    /// saving what each still holds. A tab whose save is refused stays open;
    /// the refusals say why (a conflict, a deletion, a write error).
    @discardableResult
    func close(_ paths: [String], project: Workbench) async -> [Refusal] {
        await pullPending(project)
        var refusals: [Refusal] = []
        for path in paths {
            if let buffer = existingBuffer(project, path), buffer.isDirty, !buffer.saveNow() {
                refusals.append(Refusal(path: path, reason: buffer.unsavedReason ?? "Could not save."))
                continue
            }
            mutateTabs(project) { $0.close(path) }
            forgetBuffer(project, path)
        }
        return refusals
    }

    /// Closes `paths` dropping their unsaved edits (the refusal dialog's
    /// Close and Discard).
    func discardAndClose(_ paths: [String], project: Workbench) {
        for path in paths {
            mutateTabs(project) { $0.close(path) }
            forgetBuffer(project, path)
        }
    }

    private func mutateTabs(_ project: Workbench, _ change: (inout CodeTabs) -> Void) {
        var tabs = tabsByWorkbench[project.id] ?? restoredTabs(project)
        change(&tabs)
        tabsByWorkbench[project.id] = tabs
        do {
            defaults.set(try JSONEncoder().encode(tabs), forKey: CodeTabs.key(workbenchID: project.id))
        } catch {
            NSLog("CodeFilesCenter: could not save the tabs of workbench %lld: %@", project.id, String(describing: error))
        }
    }

    // MARK: Buffers

    func buffer(for project: Workbench, relPath: String) -> CodeFileBuffer {
        let key = BufferKey(workbench: project.id, path: relPath)
        if let buffer = buffers[key] { return buffer }
        let buffer = CodeFileBuffer(url: project.folderURL.appendingPathComponent(relPath), relPath: relPath)
        buffers[key] = buffer
        return buffer
    }

    /// The buffer of `path` if one is loaded — also after a preview tab was
    /// replaced, so an edit the page sends late still lands.
    func existingBuffer(_ project: Workbench, _ path: String) -> CodeFileBuffer? {
        buffers[BufferKey(workbench: project.id, path: path)]
    }

    func buffer(id: String) -> CodeFileBuffer? {
        buffers.values.first { $0.id == id }
    }

    /// The loaded buffers of `project` at `path` or under it (a folder) —
    /// never another workbench's, whatever the paths.
    func buffers(under path: String, project: Workbench) -> [CodeFileBuffer] {
        buffers.compactMap { key, buffer in
            key.workbench == project.id && (key.path == path || key.path.hasPrefix(path + "/")) ? buffer : nil
        }
    }

    private func forgetBuffer(_ project: Workbench, _ path: String) {
        let key = BufferKey(workbench: project.id, path: path)
        buffers[key]?.cancelAutosave()
        buffers[key] = nil
    }

    // MARK: Flushing

    func register(_ bridge: CodeEditorBridge, for project: Workbench) {
        bridges[project.id] = WeakBridge(bridge: bridge, project: project)
    }

    func unregister(_ bridge: CodeEditorBridge, for workbenchID: Int64) {
        if bridges[workbenchID]?.bridge === bridge { bridges[workbenchID] = nil }
    }

    /// The page's unsent edits of `project` go into their buffers. A page
    /// that cannot be asked is logged and shown — its last 300 ms of typing
    /// may be lost, and the owner should know.
    func pullPending(_ project: Workbench) async {
        guard let bridge = bridges[project.id]?.bridge else { return }
        guard let edits = await bridge.takePending() else {
            NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its unsent edits", project.id)
            editorErrors[project.id] = "The editor did not answer; edits typed in the last moment may not be saved."
            return
        }
        if editorErrors[project.id]?.hasPrefix("The editor did not answer") == true { editorErrors[project.id] = nil }
        apply(edits, project: project, now: false)
    }

    /// Edits the page handed over (a pull, the pane going away).
    func apply(_ edits: [CodeEditorPendingEdit], project: Workbench, now: Bool) {
        for edit in edits {
            guard let buffer = buffer(id: edit.id) else {
                NSLog("CodeFilesCenter: an edit for a buffer no longer open was dropped")
                continue
            }
            edited(buffer, text: edit.text, base: edit.base, project: project, now: now)
        }
    }

    /// One edit from the page: into its buffer, and the first edit keeps a
    /// preview tab.
    func edited(_ buffer: CodeFileBuffer, text: String, base: Int, project: Workbench, now: Bool = false, explicit: Bool = false) {
        buffer.edited(text, base: base, now: now, explicit: explicit)
        let tabs = tabsByWorkbench[project.id] ?? restoredTabs(project)
        if buffer.isDirty, tabs.tabs.first(where: { $0.path == buffer.relPath })?.isPreview == true {
            pin(buffer.relPath, project: project)
        }
    }

    /// The app lost focus: everything typed goes to disk now.
    func flushEverything() async {
        for entry in bridges.values {
            guard let bridge = entry.bridge, let edits = await bridge.takePending() else { continue }
            // Through `apply`: the first edit keeps a preview tab here too.
            apply(edits, project: entry.project, now: false)
        }
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

    /// A branch switch is about to rewrite `workTree` (the repository's work
    /// tree): the unsent edits of `project` and of any workbench inside the
    /// work tree are pulled and every buffer there saved, so the switch's
    /// dirty check sees them on disk. Unlike a close or a rename, a page
    /// that does not answer stops the switch: the files would be swapped
    /// under edits nobody has.
    func saveEdits(project: Workbench, workTree: String) async -> WorkTreeSave {
        let root = TerminalCenter.resolvedPath(workTree)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        func inside(_ path: String) -> Bool {
            let resolved = TerminalCenter.resolvedPath(path)
            return resolved == root || resolved.hasPrefix(prefix)
        }
        var silent = false
        for entry in bridges.values where entry.project.id == project.id || inside(entry.project.folderPath) {
            guard let bridge = entry.bridge else { continue }
            guard let edits = await takePending(bridge, project: entry.project) else {
                NSLog("CodeFilesCenter: the editor of workbench %lld did not hand over its edits before a branch switch", entry.project.id)
                silent = true
                continue
            }
            apply(edits, project: entry.project, now: false)
        }
        if silent { return .editorSilent }
        let affected = buffers
            .filter { key, buffer in key.workbench == project.id || inside(buffer.url.path) }
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
    private func takePending(_ bridge: CodeEditorBridge, project: Workbench) async -> [CodeEditorPendingEdit]? {
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
                    self.apply(edits, project: project, now: false)
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
    func createFile(_ input: String, in directory: String, project: Workbench) throws -> String {
        let path = try CodeFileName.resolve(input, in: directory)
        let url = project.folderURL.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw OperationError.exists(path) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        revealInTree(path, project: project)
        open(path, project: project, preview: false)
        return path
    }

    @discardableResult
    func createFolder(_ input: String, in directory: String, project: Workbench) throws -> String {
        let path = try CodeFileName.resolve(input, in: directory)
        let url = project.folderURL.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw OperationError.exists(path) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        revealInTree(path, project: project)
        tree(for: project).expand(path)
        return path
    }

    /// Renames or moves `path` (a file or a folder) to `input`, a name or a
    /// path relative to its folder. Unsaved edits under it are saved first;
    /// its tabs and buffers follow, keeping undo. Returns the new path.
    @discardableResult
    func rename(_ path: String, to input: String, project: Workbench) async throws -> String {
        let newPath = try CodeFileName.resolve(input, in: Self.parent(path))
        guard newPath != path else { return path }
        guard !newPath.hasPrefix(path + "/") else { throw OperationError.failed("A folder cannot move into itself.") }
        await pullPending(project)
        let root = project.folderURL
        let affected = buffers(under: path, project: project)
        for buffer in affected where buffer.isDirty && !buffer.saveNow() {
            throw OperationError.unsaved(buffer.relPath)
        }
        let from = root.appendingPathComponent(path)
        let to = root.appendingPathComponent(newPath)
        let caseOnly = path.lowercased() == newPath.lowercased()
        // An open tab or buffer at the target (a file deleted on disk but
        // still open) would be shadowed by the moved one.
        let tabs = tabsByWorkbench[project.id] ?? restoredTabs(project)
        let occupied = tabs.paths.contains { $0 == newPath || $0.hasPrefix(newPath + "/") }
            || !buffers(under: newPath, project: project).isEmpty
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
            buffers[BufferKey(workbench: project.id, path: buffer.relPath)] = nil
            buffer.moved(to: root.appendingPathComponent(moved), relPath: moved)
            buffers[BufferKey(workbench: project.id, path: moved)] = buffer
        }
        mutateTabs(project) { $0.rename(path, to: newPath) }
        let tree = tree(for: project)
        tree.refresh(directories: [Self.parent(path), Self.parent(newPath)])
        revealInTree(newPath, project: project)
        return newPath
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
    func moveToTrash(_ path: String, project: Workbench) async throws {
        await pullPending(project)
        let gone = buffers(under: path, project: project)
        for buffer in gone where buffer.isDirty && !buffer.saveNow() {
            throw OperationError.unsaved(buffer.relPath)
        }
        do {
            try trash(project.folderURL.appendingPathComponent(path))
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        for buffer in gone {
            buffer.cancelAutosave()
            buffers[BufferKey(workbench: project.id, path: buffer.relPath)] = nil
        }
        mutateTabs(project) { $0.closeTree(path) }
        tree(for: project).refresh(directories: [Self.parent(path)])
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

    private func revealInTree(_ path: String, project: Workbench) {
        let tree = tree(for: project)
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
    let workbench: Int64
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
    let project: Workbench
}
