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
    func takePending() async -> [CodeEditorPendingEdit]
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
    @ObservationIgnored private var buffers: [String: CodeFileBuffer] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]
    @ObservationIgnored private var folders: [Int64: URL] = [:]
    @ObservationIgnored private var bridges: [Int64: WeakBridge] = [:]
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
    /// per workbench and folder) and its git status read.
    func startWatching(_ project: Workbench) {
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

    /// What FSEvents saw; internal for tests.
    func handle(_ batch: FolderWatcher.Batch, projectID: Int64) {
        guard let root = folders[projectID] else { return }
        let tree = trees[projectID]
        if batch.mustRescan {
            tree?.reloadAll()
            for buffer in buffers.values where buffer.url.path.hasPrefix(root.path + "/") {
                buffer.diskChanged()
            }
        } else {
            if !batch.paths.isEmpty { tree?.refresh(directories: Set(batch.paths.map(Self.parent))) }
            for rel in batch.paths {
                buffers[root.appendingPathComponent(rel).path]?.diskChanged()
            }
        }
        if !batch.isEmpty { refreshGit(projectID) }
    }

    private func refreshAllGit() {
        folders.keys.forEach(refreshGit)
    }

    /// One `git status` at a time per workbench, at most one per
    /// `gitMinInterval`; a change during a run queues exactly one more. A
    /// failed run keeps the last good marks and says why.
    private func refreshGit(_ projectID: Int64) {
        guard let folder = folders[projectID] else { return }
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

    func open(_ path: String, project: Workbench, preview: Bool) {
        mutateTabs(project) { $0.open(path, preview: preview) }
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
        let url = project.folderURL.appendingPathComponent(relPath)
        if let buffer = buffers[url.path] { return buffer }
        let buffer = CodeFileBuffer(url: url, relPath: relPath)
        buffers[url.path] = buffer
        return buffer
    }

    /// The buffer of `path` if one is loaded — also after a preview tab was
    /// replaced, so an edit the page sends late still lands.
    func existingBuffer(_ project: Workbench, _ path: String) -> CodeFileBuffer? {
        buffers[project.folderURL.appendingPathComponent(path).path]
    }

    func buffer(id: String) -> CodeFileBuffer? {
        buffers.values.first { $0.id == id }
    }

    private func forgetBuffer(_ project: Workbench, _ path: String) {
        let key = project.folderURL.appendingPathComponent(path).path
        buffers[key]?.cancelAutosave()
        buffers[key] = nil
    }

    // MARK: Flushing

    func register(_ bridge: CodeEditorBridge, for workbenchID: Int64) {
        bridges[workbenchID] = WeakBridge(bridge: bridge)
    }

    func unregister(_ bridge: CodeEditorBridge, for workbenchID: Int64) {
        if bridges[workbenchID]?.bridge === bridge { bridges[workbenchID] = nil }
    }

    /// The page's unsent edits of `project` go into their buffers.
    func pullPending(_ project: Workbench) async {
        guard let bridge = bridges[project.id]?.bridge else { return }
        apply(await bridge.takePending(), now: false)
    }

    /// Edits the page handed over (a pull, the pane going away).
    func apply(_ edits: [CodeEditorPendingEdit], now: Bool) {
        for edit in edits {
            buffer(id: edit.id)?.edited(edit.text, base: edit.base, now: now)
        }
    }

    /// The app lost focus: everything typed goes to disk now.
    func flushEverything() async {
        for entry in bridges.values {
            if let bridge = entry.bridge { apply(await bridge.takePending(), now: false) }
        }
        flushAll()
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
        await pullPending(project)
        let root = project.folderURL
        let affected = buffers.values.filter { $0.relPath == path || $0.relPath.hasPrefix(path + "/") }
        for buffer in affected where buffer.isDirty && !buffer.saveNow() {
            throw OperationError.unsaved(buffer.relPath)
        }
        let from = root.appendingPathComponent(path)
        let to = root.appendingPathComponent(newPath)
        let caseOnly = path.lowercased() == newPath.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: to.path) { throw OperationError.exists(newPath) }
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if caseOnly {
                // A case-insensitive volume sees the target as the source.
                let step = from.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                try FileManager.default.moveItem(at: from, to: step)
                try FileManager.default.moveItem(at: step, to: to)
            } else {
                try FileManager.default.moveItem(at: from, to: to)
            }
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        for buffer in affected {
            let moved = newPath + buffer.relPath.dropFirst(path.count)
            buffers[buffer.url.path] = nil
            buffer.moved(to: root.appendingPathComponent(moved), relPath: moved)
            buffers[buffer.url.path] = buffer
        }
        mutateTabs(project) { $0.rename(path, to: newPath) }
        let tree = tree(for: project)
        tree.refresh(directories: [Self.parent(path), Self.parent(newPath)])
        revealInTree(newPath, project: project)
        return newPath
    }

    /// Moves `path` (a file or a folder) to the macOS Trash; its tabs close.
    func moveToTrash(_ path: String, project: Workbench) throws {
        do {
            try trash(project.folderURL.appendingPathComponent(path))
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
        let gone = buffers.values.filter { $0.relPath == path || $0.relPath.hasPrefix(path + "/") }
        for buffer in gone {
            buffer.cancelAutosave()
            buffers[buffer.url.path] = nil
        }
        mutateTabs(project) { $0.closeTree(path) }
        tree(for: project).refresh(directories: [Self.parent(path)])
    }

    /// How many files a folder holds, for the Trash confirmation.
    nonisolated static func fileCount(at url: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
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

private struct WeakBridge {
    weak var bridge: CodeEditorBridge?
}
