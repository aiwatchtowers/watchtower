import Foundation
import WatchtowerCore

/// The symbol index of every workbench on screen (spec §7), on `AppState`
/// so navigating away and back within `idleTTL` (5 minutes) keeps it —
/// the `EmbeddedChatCenter` idle-release shape. `CodeFilesCenter` reports
/// when FILES or the Files pane shows a workbench and forwards its
/// `FolderWatcher` batches; Open Quickly reads `index(for:)`.
///
/// One run per workbench at a time: a full `code index --json` (first show,
/// a rescan, a show after a failure) or one request to the workbench's
/// long-lived `code index --serve` with the changed paths (after a 300 ms
/// debounce). Changes that arrive meanwhile wait and merge into the next
/// request, so results are applied in the order the runs were made.
///
/// Not observable itself: views observe the `WorkbenchCodeIndex` they get,
/// and `index(for:)` may create one while a view body runs.
@MainActor
final class CodeIndexCenter {
    private var indexes: [Int64: WorkbenchCodeIndex] = [:]
    private var sessions: [Int64: CodeIndexSession] = [:]
    private let resolveExecutable: () -> String?
    private let environment: () -> [String: String]
    private let debounce: Duration
    private let idleTTL: TimeInterval
    private let clock: () -> Date
    private let hiddenNames: Set<String>
    /// A changed folder holding more files than this is reindexed in full.
    private let expansionCap: Int

    init(
        resolveExecutable: @escaping () -> String? = Constants.findCLIPath,
        environment: @escaping () -> [String: String] = Constants.resolvedEnvironment,
        debounce: Duration = .milliseconds(300),
        idleTTL: TimeInterval = 300,
        clock: @escaping () -> Date = Date.init,
        hiddenNames: Set<String> = CodeFileTree.hiddenNames,
        expansionCap: Int = 2000
    ) {
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.debounce = debounce
        self.idleTTL = idleTTL
        self.clock = clock
        self.hiddenNames = hiddenNames
        self.expansionCap = expansionCap
    }

    /// The workbench's index — empty and `.idle` until a view shows the
    /// workbench (`markShown`). The same instance until it is released.
    func index(for workbenchID: Int64) -> WorkbenchCodeIndex {
        if let index = indexes[workbenchID] { return index }
        let index = WorkbenchCodeIndex()
        indexes[workbenchID] = index
        return index
    }

    /// A view shows the workbench: the first show (or one after a failure,
    /// or with a new folder) starts a full run. Balanced by `markHidden`.
    func markShown(workbenchID: Int64, folder: URL) {
        if let stale = sessions[workbenchID], stale.folder != folder {
            // The workbench moved to another folder: nothing of the old index holds.
            release(workbenchID)
        }
        let session = sessions[workbenchID] ?? CodeIndexSession(folder: folder, index: index(for: workbenchID))
        sessions[workbenchID] = session
        session.shownCount += 1
        session.hiddenSince = nil
        switch session.index.state {
        case .idle, .failed:
            guard session.run == nil else { return }
            session.fullPending = true
            pump(session)
        case .indexing, .ready:
            break
        }
    }

    func markHidden(workbenchID: Int64) {
        guard let session = sessions[workbenchID] else { return }
        session.shownCount = max(0, session.shownCount - 1)
        if session.shownCount == 0 { session.hiddenSince = clock() }
    }

    /// What FSEvents saw in the workbench's folder (from `CodeFilesCenter`).
    /// Ignored for a workbench with no index.
    func handle(_ batch: FolderWatcher.Batch, workbenchID: Int64) {
        guard let session = sessions[workbenchID] else { return }
        if batch.mustRescan {
            session.fullPending = true
            pump(session)
        }
        let paths = batch.paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        session.debouncing.formUnion(paths)
        session.debounceTask?.cancel()
        let debounce = debounce
        session.debounceTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, let session else { return }
            session.queued.formUnion(session.debouncing)
            session.debouncing = []
            pump(session)
        }
    }

    /// Releases the indexes no view has shown for `idleTTL` (the app's
    /// minute timer, like `EmbeddedChatCenter.sweep`).
    func sweep(now: Date? = nil) {
        let now = now ?? clock()
        for (id, session) in sessions where session.shownCount == 0 {
            guard let since = session.hiddenSince, now.timeIntervalSince(since) >= idleTTL else { continue }
            release(id)
        }
    }

    /// App quit: every child is killed.
    func stopAll() {
        for id in Array(sessions.keys) { release(id) }
    }

    private func release(_ workbenchID: Int64) {
        sessions.removeValue(forKey: workbenchID)?.stop()
        indexes[workbenchID] = nil
    }

    // MARK: Runs

    /// Starts the next run if none is in flight: a pending full run first
    /// (it covers every queued path), else one update for the queued paths.
    private func pump(_ session: CodeIndexSession) {
        guard session.run == nil, sessions.values.contains(where: { $0 === session }) else { return }
        if session.fullPending {
            session.fullPending = false
            session.queued = []
            startFullRun(session)
            return
        }
        guard !session.queued.isEmpty else { return }
        let changed = session.queued
        session.queued = []
        guard let paths = CodeIndexPathExpansion.files(
            for: changed, in: session.folder, hidden: hiddenNames, cap: expansionCap
        ) else {
            startFullRun(session)
            return
        }
        if !paths.isEmpty { startUpdate(session, paths: paths) }
    }

    private func startFullRun(_ session: CodeIndexSession) {
        let index = session.index
        let process: CodeCLIProcess
        do {
            process = try launch(["code", "index", "--folder", session.folder.path, "--json"])
        } catch {
            index.state = .failed(error.localizedDescription)
            return
        }
        let runID = session.beginRun(.full(process))
        let total = index.files.count
        index.beginFullRun()
        index.state = .indexing(done: 0, total: total)
        process.streamDecodedLines(as: CodeIndexLine.self) { [weak session] lines in
            guard let session, session.isCurrent(runID) else { return }
            index.apply(lines, from: .fullRun)
            session.fullRunLines += lines.count
            if lines.contains(where: \.isDone) {
                session.fullRunFinished = true
                index.finishFullRun()
                index.state = .ready
            } else {
                index.state = .indexing(done: session.fullRunLines, total: total)
            }
        } onExit: { [weak self, weak session] exit, _ in
            guard let self, let session, session.isCurrent(runID) else { return }
            session.run = nil
            if !session.fullRunFinished {
                index.abandonFullRun()
                let message = exit.succeeded ? "The index run stopped before it finished." : exit.failureMessage(command: "code index")
                index.state = .failed(message)
                NSLog("CodeIndexCenter: full index of %@ failed: %@", session.folder.path, message)
            }
            pump(session)
        }
    }

    private func startUpdate(_ session: CodeIndexSession, paths: [String]) {
        let serve: CodeCLIProcess
        do {
            serve = try session.serve ?? startServe(session)
        } catch {
            session.index.state = .failed(error.localizedDescription)
            session.queued.formUnion(paths)
            return
        }
        _ = session.beginRun(.update(paths))
        serve.send(paths.joined(separator: "\t"))
    }

    private func startServe(_ session: CodeIndexSession) throws -> CodeCLIProcess {
        let process = try launch(["code", "index", "--folder", session.folder.path, "--serve"])
        session.serve = process
        let index = session.index
        process.streamDecodedLines(as: CodeIndexLine.self) { [weak self, weak session] lines in
            guard let self, let session, session.serve === process, case .update = session.run else { return }
            index.apply(lines, from: .update)
            guard lines.contains(where: \.isDone) else { return }
            session.run = nil
            if case .failed = index.state, session.fullRunFinished { index.state = .ready }
            pump(session)
        } onExit: { [weak session] exit, _ in
            guard let session, session.serve === process else { return }
            session.serve = nil
            NSLog("CodeIndexCenter: code index --serve for %@ exited: %@", session.folder.path, exit.stderr)
            guard case let .update(paths) = session.run else { return }
            // The request is lost with the process: its paths wait for the
            // next change (or show) to be asked again.
            session.run = nil
            session.queued.formUnion(paths)
            index.state = .failed(exit.failureMessage(command: "code index --serve"))
        }
        return process
    }

    private func launch(_ arguments: [String]) throws -> CodeCLIProcess {
        guard let executable = resolveExecutable() else { throw CodeCLIProcess.LaunchError.notFound }
        return try CodeCLIProcess.launch(executable: executable, arguments: arguments, environment: environment())
    }
}

/// One workbench's runs: what is in flight, what waits, the `--serve` child.
@MainActor
private final class CodeIndexSession {
    enum Run {
        case full(CodeCLIProcess)
        /// A request written to `serve`, answered by its next done line.
        case update([String])
    }

    let folder: URL
    let index: WorkbenchCodeIndex
    var shownCount = 0
    var hiddenSince: Date?
    var run: Run?
    var serve: CodeCLIProcess?
    /// A full run reached its done line: the index is complete (updates
    /// keep it so), so a later update may clear a `--serve` failure.
    var fullRunFinished = false
    /// Lines the full run in flight has delivered.
    var fullRunLines = 0
    var fullPending = false
    /// Changed paths waiting for the run in flight.
    var queued: Set<String> = []
    /// Changed paths inside the debounce window.
    var debouncing: Set<String> = []
    var debounceTask: Task<Void, Never>?
    private var runID = 0

    init(folder: URL, index: WorkbenchCodeIndex) {
        self.folder = folder
        self.index = index
    }

    func beginRun(_ run: Run) -> Int {
        runID += 1
        self.run = run
        if case .full = run {
            fullRunFinished = false
            fullRunLines = 0
        }
        return runID
    }

    func isCurrent(_ id: Int) -> Bool {
        runID == id
    }

    /// Kills every child; late lines and exits of the old runs are ignored.
    func stop() {
        runID += 1
        debounceTask?.cancel()
        if case let .full(process) = run { process.terminate() }
        run = nil
        serve?.terminate()
        serve = nil
    }
}

/// Changed paths → the files to ask `--serve` for. FSEvents may report a
/// folder (created, moved in) without its files: an existing folder is
/// replaced by the files under it (hidden names skipped). A path that is
/// gone stays as given — the CLI answers `deleted`, which removes it and,
/// for a folder, everything under it.
enum CodeIndexPathExpansion {
    /// nil when more than `cap` files changed: a full run is cheaper.
    static func files(for changed: Set<String>, in folder: URL, hidden: Set<String>, cap: Int) -> [String]? {
        var out = Set<String>()
        for rel in changed.sorted() {
            // A request line is tab-separated, one line: such a name cannot be sent.
            guard !rel.contains("\t"), !rel.contains("\n") else {
                NSLog("CodeIndexCenter: not indexing a path with a tab or newline: %@", rel)
                continue
            }
            let url = folder.appendingPathComponent(rel)
            // No values = the path is gone: sent as is, answered `deleted`.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                guard let inside = filesUnder(url, rel: rel, hidden: hidden, cap: cap - out.count) else { return nil }
                out.formUnion(inside)
            } else {
                out.insert(rel)
            }
            if out.count > cap { return nil }
        }
        return out.sorted()
    }

    /// The regular files under a folder (an unreadable one lists nothing:
    /// its files reach the index with the next full run).
    private static func filesUnder(_ url: URL, rel: String, hidden: Set<String>, cap: Int) -> [String]? {
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return [] }
        var out: [String] = []
        while let inner = walker.nextObject() as? String {
            let name = (inner as NSString).lastPathComponent
            if hidden.contains(name) || name == ".git" {
                walker.skipDescendants()
                continue
            }
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            out.append(rel + "/" + inner)
            if out.count > cap { return nil }
        }
        return out
    }
}
