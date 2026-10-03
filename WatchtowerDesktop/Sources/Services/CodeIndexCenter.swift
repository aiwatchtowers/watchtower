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
/// The owner's rules file (`code-languages.yaml`, spec §6.5) is read once
/// per CLI process, so a change to it (500 ms debounce) kills every run in
/// flight and every `--serve` child — the next update starts a fresh one —
/// and runs a full index for the workbenches on screen; a hidden one gets
/// its full run when it is shown again.
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
    /// The debounce never holds a change longer than this: a folder written
    /// continuously (a log, test output) would otherwise reset it forever.
    private let debounceMaxWait: Duration
    private let idleTTL: TimeInterval
    private let clock: () -> Date
    private let hiddenNames: Set<String>
    /// A changed folder holding more files than this is reindexed in full.
    private let expansionCap: Int
    /// The rules file watched; passed to the CLI as `--rules` only when
    /// pinned (tests), since the CLI's default is `defaultRulesFile`.
    private let rulesFile: URL
    private let pinsRulesFile: Bool
    private let rulesDebounce: Duration
    private var rulesWatcher: CodeRulesFileWatcher?
    /// The rules folder could not be created: said once, not on every show.
    private var rulesFolderFailureLogged = false
    private var rulesDebounceTask: Task<Void, Never>?

    /// Where `watchtower code index` reads the rules file from by default —
    /// must stay the path Go builds from `os.UserHomeDir()` ($HOME).
    static let defaultRulesFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Watchtower/code-languages.yaml")

    init(
        resolveExecutable: @escaping () -> String? = Constants.findCLIPath,
        environment: @escaping () -> [String: String] = Constants.resolvedEnvironment,
        debounce: Duration = .milliseconds(300),
        debounceMaxWait: Duration = .seconds(1),
        idleTTL: TimeInterval = 300,
        clock: @escaping () -> Date = Date.init,
        hiddenNames: Set<String> = CodeFileTree.hiddenNames,
        expansionCap: Int = 2000,
        rulesFile: URL? = nil,
        rulesDebounce: Duration = .milliseconds(500)
    ) {
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.debounce = debounce
        self.debounceMaxWait = debounceMaxWait
        self.idleTTL = idleTTL
        self.clock = clock
        self.hiddenNames = hiddenNames
        self.expansionCap = expansionCap
        self.rulesFile = rulesFile ?? Self.defaultRulesFile
        pinsRulesFile = rulesFile != nil
        self.rulesDebounce = rulesDebounce
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
        watchRulesFile()
        if let stale = sessions[workbenchID], stale.folder != folder {
            // The workbench moved to another folder: nothing of the old index holds.
            releaseIndex(workbenchID)
        }
        let session = sessions[workbenchID] ?? CodeIndexSession(folder: folder, index: index(for: workbenchID))
        sessions[workbenchID] = session
        session.shownCount += 1
        session.hiddenSince = nil
        switch session.index.state {
        case .idle, .failed:
            guard session.run == nil else { return }
            session.fullPending = true
        case .indexing, .ready:
            break
        }
        // A first show, one after a failure, or one after the rules file
        // changed while the workbench was hidden.
        if session.fullPending { startNextRun(session) }
    }

    func markHidden(workbenchID: Int64) {
        guard let session = sessions[workbenchID] else { return }
        session.shownCount = max(0, session.shownCount - 1)
        if session.shownCount == 0 { session.hiddenSince = clock() }
    }

    /// What FSEvents saw in the workbench's folder (from `CodeFilesCenter`).
    /// Ignored for a workbench with no index. Paths wait `debounce` after
    /// the last batch, but never more than `debounceMaxWait` after the first
    /// one; a rescan's full run covers whatever was waiting.
    func applyWatcherBatch(_ batch: FolderWatcher.Batch, workbenchID: Int64) {
        guard let session = sessions[workbenchID] else { return }
        if batch.mustRescan {
            session.debounceTask?.cancel()
            session.debounceTask = nil
            session.debouncing = []
            session.fullPending = true
            startNextRun(session)
            return
        }
        let paths = batch.paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        let now = ContinuousClock.now
        if session.debouncing.isEmpty { session.debounceDeadline = now + debounceMaxWait }
        session.debouncing.formUnion(paths)
        session.debounceTask?.cancel()
        let wait = max(.zero, min(debounce, session.debounceDeadline - now))
        session.debounceTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let session else { return }
            session.queued.formUnion(session.debouncing)
            session.debouncing = []
            startNextRun(session)
        }
    }

    /// Releases the indexes no view has shown for `idleTTL` (the app's
    /// minute timer, like `EmbeddedChatCenter.sweep`).
    func releaseIdleIndexes(now: Date? = nil) {
        let now = now ?? clock()
        for (id, session) in sessions where session.shownCount == 0 {
            guard let since = session.hiddenSince, now.timeIntervalSince(since) >= idleTTL else { continue }
            releaseIndex(id)
        }
    }

    /// App quit: every child is killed, the rules file no longer watched.
    func stopAll() {
        rulesDebounceTask?.cancel()
        rulesDebounceTask = nil
        rulesWatcher?.stopWatchingRulesFile()
        rulesWatcher = nil
        for id in Array(sessions.keys) { releaseIndex(id) }
    }

    // MARK: Rules file

    /// Starts watching the rules file on the first show. Its folder may not
    /// exist yet: then the next show tries again.
    private func watchRulesFile() {
        guard rulesWatcher == nil else { return }
        // The app owns the folder: created now, so a rules file written
        // later is seen (a watcher started after it would take it as the
        // baseline and never reindex).
        let folder = rulesFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            if !rulesFolderFailureLogged {
                rulesFolderFailureLogged = true
                NSLog("CodeIndexCenter: cannot create %@ to watch the rules file: %@", folder.path, error.localizedDescription)
            }
            return
        }
        rulesWatcher = CodeRulesFileWatcher(file: rulesFile) { [weak self] in
            self?.rulesFileChanged()
        }
        if rulesWatcher == nil, !rulesFolderFailureLogged {
            rulesFolderFailureLogged = true
            NSLog("CodeIndexCenter: cannot watch the rules file folder %@", folder.path)
        }
    }

    private func rulesFileChanged() {
        rulesDebounceTask?.cancel()
        rulesDebounceTask = Task { @MainActor [weak self, rulesDebounce] in
            try? await Task.sleep(for: rulesDebounce)
            guard !Task.isCancelled, let self else { return }
            rulesDebounceTask = nil
            reindexForRules()
        }
    }

    /// Every CLI process read the old rules: each is killed and a full run
    /// waits — started now for a workbench on screen.
    private func reindexForRules() {
        for session in sessions.values {
            session.dropRunsForRulesChange()
            if session.shownCount > 0 { startNextRun(session) }
        }
    }

    private func releaseIndex(_ workbenchID: Int64) {
        sessions.removeValue(forKey: workbenchID)?.stopChildren()
        indexes[workbenchID] = nil
    }

    // MARK: Runs

    /// Starts the next run if none is in flight: a pending full run first
    /// (it covers every queued path), else one update for the queued paths.
    private func startNextRun(_ session: CodeIndexSession) {
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
            process = try launch(indexArguments(session.folder, mode: "--json"))
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
            index.applyIndexLines(lines, from: .fullRun)
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
            startNextRun(session)
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
        serve.sendLine(paths.joined(separator: "\t"))
    }

    private func startServe(_ session: CodeIndexSession) throws -> CodeCLIProcess {
        let process = try launch(indexArguments(session.folder, mode: "--serve"))
        session.serve = process
        let index = session.index
        process.streamDecodedLines(as: CodeIndexLine.self) { [weak self, weak session] lines in
            guard let self, let session, session.serve === process, case .update = session.run else { return }
            index.applyIndexLines(lines, from: .update)
            guard lines.contains(where: \.isDone) else { return }
            session.run = nil
            if case .failed = index.state, session.fullRunFinished { index.state = .ready }
            startNextRun(session)
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

    /// `code index` over the folder, with `--rules` only when pinned.
    private func indexArguments(_ folder: URL, mode: String) -> [String] {
        ["code", "index", "--folder", folder.path] + (pinsRulesFile ? ["--rules", rulesFile.path] : []) + [mode]
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
    /// When the waiting paths must go out at the latest.
    var debounceDeadline = ContinuousClock.now
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

    /// The rules file changed: the runs in flight and the `--serve` child
    /// read the old one. They are killed (their late lines and exits are
    /// ignored) and a full run — covering every waiting path — is pending.
    func dropRunsForRulesChange() {
        if case .full = run { index.abandonFullRun() }
        stopChildren()
        debounceTask = nil
        debouncing = []
        queued = []
        fullPending = true
    }

    /// Kills every child; late lines and exits of the old runs are ignored.
    func stopChildren() {
        runID += 1
        debounceTask?.cancel()
        if case let .full(process) = run { process.terminateGroup() }
        run = nil
        serve?.terminateGroup()
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
