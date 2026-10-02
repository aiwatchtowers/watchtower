import AppKit
import CoreServices
import Foundation
import Observation
import WatchtowerCore

// POC (code viewer): the FILES tree of a workbench folder, the file tabs of
// the Files pane and the buffers behind them, and the folder's git status.
// Claude Code edits the same folder while the owner looks at it, so one
// FSEvents stream per folder refreshes the tree, the git marks and the open
// files — a clean buffer reloads silently, one with unsaved edits raises a
// conflict instead of being overwritten either way. Edits save themselves
// (`CodeFileBuffer.autosaveDelay`).

/// The trees, tabs, buffers and git status of every workbench, kept for the
/// app's lifetime (owned by `WorkbenchesViewModel`, itself owned by `AppState`).
@MainActor
@Observable
final class CodeFilesCenter {
    private(set) var tabsByWorkbench: [Int64: CodeTabs] = [:]
    private(set) var gitByWorkbench: [Int64: GitStatusSnapshot] = [:]
    @ObservationIgnored private var trees: [Int64: CodeFileTree] = [:]
    @ObservationIgnored private var buffers: [String: CodeFileBuffer] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]
    @ObservationIgnored private var folders: [Int64: URL] = [:]
    @ObservationIgnored private var gitRunning: Set<Int64> = []
    @ObservationIgnored private var gitPending: Set<Int64> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAll() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllGit() }
        })
    }

    // MARK: Tree

    func tree(for project: Workbench) -> CodeFileTree {
        if let tree = trees[project.id], tree.root == project.folderURL { return tree }
        let tree = CodeFileTree(root: project.folderURL)
        trees[project.id] = tree
        watch(project)
        refreshGit(project.id)
        return tree
    }

    func git(for project: Workbench) -> GitStatusSnapshot {
        gitByWorkbench[project.id] ?? GitStatusSnapshot()
    }

    // MARK: Tabs

    func tabs(for project: Workbench) -> CodeTabs {
        if let tabs = tabsByWorkbench[project.id] { return tabs }
        var tabs = CodeTabs()
        if let data = defaults.data(forKey: CodeTabs.key(workbenchID: project.id)),
           let saved = try? JSONDecoder().decode(CodeTabs.self, from: data) {
            tabs = saved
            tabs.prune { FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path) }
        }
        // Deferred: this runs while a view body reads it.
        let id = project.id
        Task { @MainActor in if self.tabsByWorkbench[id] == nil { self.tabsByWorkbench[id] = tabs } }
        return tabs
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

    /// Closes the tabs `paths` after saving what they still hold. A tab whose
    /// save is refused (the disk moved under its edits) stays open with its
    /// conflict banner; returns those paths.
    @discardableResult
    func close(_ paths: [String], project: Workbench) -> [String] {
        var refused: [String] = []
        for path in paths {
            let buffer = existingBuffer(project, path)
            if let buffer, buffer.isDirty, !buffer.saveNow() {
                refused.append(path)
                continue
            }
            mutateTabs(project) { $0.close(path) }
            forgetBuffer(project, path)
        }
        return refused
    }

    /// Closes `path` dropping its unsaved edits (the conflict dialog's Discard).
    func discardAndClose(_ path: String, project: Workbench) {
        mutateTabs(project) { $0.close(path) }
        forgetBuffer(project, path)
    }

    private func mutateTabs(_ project: Workbench, _ change: (inout CodeTabs) -> Void) {
        var tabs = tabsByWorkbench[project.id] ?? tabs(for: project)
        change(&tabs)
        tabsByWorkbench[project.id] = tabs
        if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: CodeTabs.key(workbenchID: project.id))
        }
    }

    // MARK: Buffers

    func buffer(for project: Workbench, relPath: String) -> CodeFileBuffer {
        let url = project.folderURL.appendingPathComponent(relPath)
        if let buffer = buffers[url.path] { return buffer }
        let buffer = CodeFileBuffer(url: url, relPath: relPath)
        buffers[url.path] = buffer
        watch(project)
        return buffer
    }

    /// The buffer of `path` if one is loaded — also after a preview tab
    /// was replaced, so an edit the page sends late still lands.
    func existingBuffer(_ project: Workbench, _ path: String) -> CodeFileBuffer? {
        buffers[project.folderURL.appendingPathComponent(path).path]
    }

    private func forgetBuffer(_ project: Workbench, _ path: String) {
        let key = project.folderURL.appendingPathComponent(path).path
        buffers[key]?.cancelAutosave()
        buffers[key] = nil
    }

    /// The app lost focus: everything typed goes to disk now.
    func flushAll() {
        for buffer in buffers.values where buffer.isDirty {
            buffer.saveNow()
        }
    }

    // MARK: Watching

    private func watch(_ project: Workbench) {
        folders[project.id] = project.folderURL
        guard watchers[project.id] == nil else { return }
        let root = project.folderURL
        let projectID = project.id
        watchers[projectID] = FolderWatcher(root: root) { [weak self] relPaths, gitChanged in
            self?.handle(relPaths, gitChanged: gitChanged, root: root, projectID: projectID)
        }
    }

    private func handle(_ relPaths: Set<String>, gitChanged: Bool, root: URL, projectID: Int64) {
        if let tree = trees[projectID], !relPaths.isEmpty {
            tree.refresh(directories: Set(relPaths.map(Self.parent)))
        }
        for rel in relPaths {
            buffers[root.appendingPathComponent(rel).path]?.diskChanged()
        }
        if gitChanged || !relPaths.isEmpty { refreshGit(projectID) }
    }

    private func refreshAllGit() {
        trees.keys.forEach(refreshGit)
    }

    /// One `git status` at a time per workbench; a change during a run
    /// queues exactly one more.
    private func refreshGit(_ projectID: Int64) {
        guard let folder = folders[projectID] ?? trees[projectID]?.root else { return }
        guard !gitRunning.contains(projectID) else {
            gitPending.insert(projectID)
            return
        }
        gitRunning.insert(projectID)
        Task { @MainActor in
            let snapshot = await GitStatusSnapshot.read(folder: folder)
            gitRunning.remove(projectID)
            let updated = snapshot ?? GitStatusSnapshot()
            if gitByWorkbench[projectID] != updated { gitByWorkbench[projectID] = updated }
            if gitPending.remove(projectID) != nil { refreshGit(projectID) }
        }
    }

    nonisolated static func parent(_ relPath: String) -> String {
        let parent = (relPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

/// One entry of a listed directory.
struct CodeFileEntry: Hashable, Sendable {
    let name: String
    /// Relative to the tree's root; "" is the root itself.
    let relPath: String
    let isDirectory: Bool
}

/// A workbench folder as a lazily listed tree: a directory is read when it
/// is first expanded and re-read when FSEvents reports a change inside it.
@MainActor
@Observable
final class CodeFileTree {
    /// Never listed: VCS and build output that would bury the source.
    nonisolated static let hiddenNames: Set<String> = [
        ".git", ".build", "node_modules", ".DS_Store", ".swiftpm", "DerivedData", ".idea", ".worktrees"
    ]

    struct Row: Hashable {
        let entry: CodeFileEntry
        let depth: Int
        let isExpanded: Bool
    }

    let root: URL
    private(set) var expanded: Set<String> = [""]
    private(set) var listings: [String: [CodeFileEntry]] = [:]
    private(set) var errors: [String: String] = [:]

    init(root: URL) {
        self.root = root
    }

    /// The visible rows, depth-first: the children of every expanded
    /// directory under its row.
    var rows: [Row] {
        var out: [Row] = []
        append(children: "", depth: 0, into: &out)
        return out
    }

    private func append(children dir: String, depth: Int, into out: inout [Row]) {
        for entry in listing(dir) {
            let open = entry.isDirectory && expanded.contains(entry.relPath)
            out.append(Row(entry: entry, depth: depth, isExpanded: open))
            if open { append(children: entry.relPath, depth: depth + 1, into: &out) }
        }
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
        } else {
            expanded.insert(dir)
            load(dir)
        }
    }

    func collapseAll() {
        expanded = [""]
    }

    /// Re-reads the listed directories among `directories`; the rest are
    /// read when next expanded.
    func refresh(directories: Set<String>) {
        for dir in directories where listings[dir] != nil {
            load(dir)
        }
    }

    func reloadAll() {
        listings.keys.forEach(load)
    }

    private func listing(_ dir: String) -> [CodeFileEntry] {
        if let cached = listings[dir] { return cached }
        return []
    }

    func loadIfNeeded() {
        if listings[""] == nil { load("") }
    }

    private func load(_ dir: String) {
        let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
            let entries = urls.compactMap { child -> CodeFileEntry? in
                let name = child.lastPathComponent
                guard !Self.hiddenNames.contains(name) else { return nil }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return CodeFileEntry(name: name, relPath: dir.isEmpty ? name : dir + "/" + name, isDirectory: isDirectory)
            }
            listings[dir] = entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            errors[dir] = nil
        } catch {
            // A directory that vanished (deleted by the agent) drops out.
            if (error as NSError).code == NSFileReadNoSuchFileError {
                listings[dir] = nil
                expanded.remove(dir)
            } else {
                errors[dir] = error.localizedDescription
            }
        }
    }
}

/// One file open in a tab. The disk text is the last version read or
/// written; `text` is the editor's, synced from the page (debounced there,
/// flushed on a tab switch, a blur and Cmd+S). Edits save themselves
/// `autosaveDelay` after the last one; `isDirty` = not on disk yet.
@MainActor
@Observable
final class CodeFileBuffer {
    /// Bigger files are not opened: Monaco copes, the round trip through the
    /// JS bridge on every edit does not.
    nonisolated static let maxBytes = 5 * 1024 * 1024
    nonisolated static let autosaveDelay: Duration = .seconds(1)

    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let url: URL
    let relPath: String
    private(set) var state: State = .loading
    private(set) var diskText = ""
    private(set) var text = ""
    /// The file changed on disk while the buffer had unsaved edits.
    private(set) var conflict = false
    private(set) var deletedOnDisk = false
    /// Bumped when `text` was replaced from disk and the editor must follow.
    private(set) var externalRevision = 0
    var saveError: String?
    var editorError: String?
    @ObservationIgnored private var autosave: Task<Void, Never>?

    init(url: URL, relPath: String) {
        self.url = url
        self.relPath = relPath
    }

    var isDirty: Bool { state == .loaded && text != diskText }

    func loadIfNeeded() {
        guard state != .loaded else { return }
        switch Self.read(url) {
        case let .success(content):
            diskText = content
            text = content
            state = .loaded
        case let .failure(error):
            state = .failed(error.message)
        }
    }

    /// The editor's text. `now` (Cmd+S) saves at once; otherwise the save
    /// waits for a pause in typing.
    func edited(_ newText: String, now: Bool) {
        guard state == .loaded else { return }
        text = newText
        if now {
            saveNow()
        } else {
            scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard isDirty else { return }
        autosave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func cancelAutosave() {
        autosave?.cancel()
        autosave = nil
    }

    /// FSEvents saw the file change (our own saves included — those match
    /// the disk text and change nothing).
    func diskChanged() {
        guard state == .loaded else { return }
        switch Self.read(url) {
        case let .success(content):
            deletedOnDisk = false
            guard content != diskText else { return }
            if isDirty {
                conflict = true
            } else {
                diskText = content
                text = content
                externalRevision += 1
            }
        case .failure(.missing):
            deletedOnDisk = true
        case .failure:
            break
        }
    }

    /// Writes `text` unless the disk moved under it (then the conflict
    /// banner decides); in place, so the file keeps its permissions. True
    /// when the disk now holds `text`.
    @discardableResult
    func saveNow() -> Bool {
        cancelAutosave()
        guard state == .loaded else { return true }
        guard isDirty || deletedOnDisk else { return true }
        if conflict { return false }
        let current = Self.read(url)
        if case let .success(onDisk) = current, onDisk != diskText {
            conflict = true
            return false
        }
        do {
            if case .failure(.missing) = current {
                try Data(text.utf8).write(to: url)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data(text.utf8))
            }
            diskText = text
            deletedOnDisk = false
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Conflict banner: drop the unsaved edits, take the disk version.
    func reloadFromDisk() {
        guard case let .success(content) = Self.read(url) else { return }
        cancelAutosave()
        diskText = content
        text = content
        conflict = false
        externalRevision += 1
    }

    /// Conflict banner: keep the edits and write them over the disk version.
    func keepMine() {
        if case let .success(content) = Self.read(url) { diskText = content }
        conflict = false
        saveNow()
    }

    enum ReadError: Error {
        case missing
        case tooBig
        case notText
        case other(String)

        var message: String {
            switch self {
            case .missing: "The file no longer exists."
            case .tooBig: "The file is larger than 5 MB — open it in an external editor."
            case .notText: "Not a UTF-8 text file."
            case let .other(message): message
            }
        }
    }

    nonisolated static func read(_ url: URL) -> Result<String, ReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes else { return .failure(.tooBig) }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { return .failure(.notText) }
            return .success(text)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }
}

/// An FSEvents stream over one folder, reporting changed paths relative to
/// it (debounced by the stream's latency). Git's own churn is dropped.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let onChange: @MainActor (Set<String>, Bool) -> Void

    /// `onChange(paths, gitChanged)`: the changed paths outside .git, and
    /// whether git's index, HEAD or refs moved (a commit, a checkout).
    init(root: URL, onChange: @escaping @MainActor (Set<String>, Bool) -> Void) {
        // FSEvents reports resolved paths (/private/var, not /var).
        rootPath = root.resolvingSymlinksInPath().path
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                watcher.deliver((0 ..< count).compactMap { array[$0] as? String })
            },
            &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func deliver(_ paths: [String]) {
        let prefix = rootPath + "/"
        var rel: Set<String> = []
        var gitChanged = false
        for path in paths {
            guard path.hasPrefix(prefix) else {
                if path == rootPath { rel.insert("") }
                continue
            }
            let relPath = String(path.dropFirst(prefix.count))
            if relPath == ".git" || relPath.hasPrefix(".git/") {
                let inner = relPath.dropFirst(5)
                if inner == "index" || inner == "HEAD" || inner.hasPrefix("refs/") { gitChanged = true }
                continue
            }
            if relPath.contains("/.git/") { continue }
            rel.insert(relPath)
        }
        guard !rel.isEmpty || gitChanged else { return }
        MainActor.assumeIsolated { onChange(rel, gitChanged) }
    }
}
