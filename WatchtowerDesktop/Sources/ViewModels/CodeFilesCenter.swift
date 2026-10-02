import CoreServices
import Foundation
import Observation
import WatchtowerCore

// POC (code viewer): the FILES tree of a workbench folder and the buffers of
// the files open in the Monaco editor. Claude Code edits the same folder
// while the owner looks at it, so one FSEvents stream per folder refreshes
// the tree and reloads open files — a clean buffer silently, a dirty one
// raises a conflict instead of being overwritten either way.

/// The trees and buffers of every workbench, kept for the app's lifetime
/// (owned by `WorkbenchesViewModel`, itself owned by `AppState`).
@MainActor
@Observable
final class CodeFilesCenter {
    @ObservationIgnored private var trees: [Int64: CodeFileTree] = [:]
    @ObservationIgnored private var buffers: [String: CodeFileBuffer] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]

    func tree(for project: Workbench) -> CodeFileTree {
        if let tree = trees[project.id], tree.root == project.folderURL { return tree }
        let tree = CodeFileTree(root: project.folderURL)
        trees[project.id] = tree
        watch(project)
        return tree
    }

    func buffer(for project: Workbench, relPath: String) -> CodeFileBuffer {
        let url = project.folderURL.appendingPathComponent(relPath)
        if let buffer = buffers[url.path] { return buffer }
        let buffer = CodeFileBuffer(url: url, relPath: relPath)
        buffers[url.path] = buffer
        watch(project)
        return buffer
    }

    private func watch(_ project: Workbench) {
        guard watchers[project.id] == nil else { return }
        let root = project.folderURL
        let projectID = project.id
        watchers[projectID] = FolderWatcher(root: root) { [weak self] relPaths in
            self?.handle(relPaths, root: root, projectID: projectID)
        }
    }

    private func handle(_ relPaths: Set<String>, root: URL, projectID: Int64) {
        if let tree = trees[projectID] {
            tree.refresh(directories: Set(relPaths.map(Self.parent)))
        }
        for rel in relPaths {
            buffers[root.appendingPathComponent(rel).path]?.diskChanged()
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

/// One file open in the editor. The disk text is the last version read or
/// written; `text` is the editor's (synced from the page, debounced), kept
/// here so an unsaved edit survives the pane going away.
@MainActor
@Observable
final class CodeFileBuffer {
    /// Bigger files are not opened: Monaco copes, the round trip through the
    /// JS bridge on every edit does not.
    nonisolated static let maxBytes = 5 * 1024 * 1024

    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let url: URL
    let relPath: String
    private(set) var state: State = .loading
    private(set) var diskText = ""
    var text = ""
    var isDirty = false
    /// The file changed on disk while the buffer had unsaved edits.
    private(set) var conflict = false
    private(set) var deletedOnDisk = false
    /// Bumped when `text` was replaced from disk and the editor must follow.
    private(set) var externalRevision = 0
    /// Bumped by the pane's Save button: the editor posts its exact text
    /// back the way Cmd+S does (`text` lags it by the sync debounce).
    private(set) var saveRequests = 0
    var saveError: String?
    var editorError: String?

    init(url: URL, relPath: String) {
        self.url = url
        self.relPath = relPath
    }

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

    /// Cmd+S. Refuses when the disk moved under unsaved edits (the conflict
    /// banner decides); writes in place so the file keeps its permissions.
    @discardableResult
    func save(_ newText: String) -> Bool {
        text = newText
        if case let .success(current) = Self.read(url), current != diskText {
            conflict = true
            return false
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(newText.utf8))
            diskText = newText
            isDirty = false
            conflict = false
            deletedOnDisk = false
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func requestSave() {
        saveRequests += 1
    }

    /// Conflict banner: drop the unsaved edits, take the disk version.
    func reloadFromDisk() {
        guard case let .success(content) = Self.read(url) else { return }
        diskText = content
        text = content
        isDirty = false
        conflict = false
        externalRevision += 1
    }

    /// Conflict banner: keep the edits; the next save overwrites the disk.
    func keepMine() {
        if case let .success(content) = Self.read(url) { diskText = content }
        conflict = false
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
    private let onChange: @MainActor (Set<String>) -> Void

    init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
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
        let rel = Set(paths.compactMap { path -> String? in
            guard path.hasPrefix(prefix) else { return path == rootPath ? "" : nil }
            let relPath = String(path.dropFirst(prefix.count))
            if relPath == ".git" || relPath.hasPrefix(".git/") || relPath.contains("/.git/") { return nil }
            return relPath
        })
        guard !rel.isEmpty else { return }
        MainActor.assumeIsolated { onChange(rel) }
    }
}
