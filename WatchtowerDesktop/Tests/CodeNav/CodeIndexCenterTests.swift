import GRDB
import WatchtowerChatText
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// `CodeIndexCenter` (spec §7) against a stub CLI: the index survives
/// navigation and is released after 5 idle minutes; watcher batches are
/// debounced into one `--serve` request, a batch during a run waits and
/// merges (Review Focus 3); a rescan is a full run; a failing CLI shows its
/// stderr; a change to the rules file (pinned to a temp file) restarts the
/// `--serve` child and runs a full index. Every stub process group is
/// reaped in tearDown.
@MainActor
final class CodeIndexCenterTests: XCTestCase {
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private var stub: CodeCLIStub!
    private var folder: URL!
    /// The pinned rules file, outside the workbench folder.
    private var rulesFile: URL!
    private var center: CodeIndexCenter?
    private let clock = TestClock()

    override func setUp() async throws {
        stub = try CodeCLIStub()
        folder = stub.directory.appendingPathComponent("workbench")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib/node_modules"), withIntermediateDirectories: true)
        for path in ["lib/a.swift", "lib/sub/b.swift", "lib/node_modules/x.js"] {
            try "x\n".write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let support = stub.directory.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        rulesFile = support.appendingPathComponent("code-languages.yaml")
        try "# no rules\n".write(to: rulesFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        center?.stopAll()
        center = nil
        await stub.assertAllGroupsReaped()
        stub.remove()
    }

    private func makeCenter(
        _ env: [String: String] = [:],
        executable: String? = nil,
        rulesDebounce: Duration = .milliseconds(500),
        debounceClock: HandMovedDebounceClock? = nil
    ) -> CodeIndexCenter {
        let path = executable ?? stub.executable.path
        let environment = stub.environment(["STUB_FILES": "one.swift two.swift"].merging(env) { $1 })
        let made = CodeIndexCenter(
            resolveExecutable: { path }, environment: { environment },
            debounceNow: { debounceClock?.now ?? .now },
            debounceSleep: { wait in
                if let debounceClock { try await debounceClock.sleep(for: wait) } else { try await Task.sleep(for: wait) }
            },
            clock: { [clock] in clock.now }, rulesFile: rulesFile, rulesDebounce: rulesDebounce
        )
        center = made
        return made
    }

    /// The main code root of workbench `id` at the test folder.
    private func root(_ id: Int64) -> CodeRoot {
        Workbench(row: Row(["id": id, "name": "acme", "folder_path": folder.path])).mainCodeRoot
    }

    // MARK: Lifetime

    func testNavigatingAwayAndBackKeepsTheIndexAndFiveIdleMinutesReleaseIt() async {
        let center = makeCenter(["STUB_FULL_DELAY": "0.3"])
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        XCTAssertEqual(index.state, .indexing(done: 0, total: 0))
        center.markHidden(root: root(7)) // navigated away while it runs
        center.markShown(root: root(7))
        center.markHidden(root: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(index.files, ["one.swift", "two.swift"])

        clock.now += 299
        center.releaseIdleIndexes()
        center.markShown(root: root(7)) // back within 5 minutes
        XCTAssertTrue(center.index(for: root(7)) === index)
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(stub.fullRuns, 1, "coming back does not reindex")

        center.markHidden(root: root(7))
        clock.now += 299
        center.releaseIdleIndexes()
        XCTAssertTrue(center.index(for: root(7)) === index)
        clock.now += 1
        center.releaseIdleIndexes()
        let fresh = center.index(for: root(7))
        XCTAssertFalse(fresh === index, "released after 5 idle minutes")
        XCTAssertEqual(fresh.state, .idle)
        XCTAssertEqual(fresh.files, [])
    }

    func testReleasingKillsARunInFlight() async {
        let center = makeCenter(["STUB_FULL_DELAY": "30"])
        center.markShown(root: root(7))
        let started = await eventually { self.stub.fullRuns == 1 }
        XCTAssertTrue(started)
        center.markHidden(root: root(7))
        center.releaseIdleIndexes(now: clock.now + 300)
        await stub.assertAllGroupsReaped()
    }

    func testAMovedMainFolderReleasesTheStaleMainIndexAndAWorktreeNeverDoes() throws {
        let moved = stub.directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let movedRoot = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": moved.path])).mainCodeRoot
        let worktree = CodeRoot(workbenchID: 7, worktree: moved.appendingPathComponent("wt"))
        let center = makeCenter()
        center.markShown(root: root(7))
        let mainIndex = center.index(for: root(7))

        center.markShown(root: worktree)
        let worktreeIndex = center.index(for: worktree)
        XCTAssertTrue(center.index(for: root(7)) === mainIndex, "a worktree root never releases the main index")
        let otherWorkbench = root(8)
        center.markShown(root: otherWorkbench)
        XCTAssertTrue(center.index(for: root(7)) === mainIndex, "another workbench's main root leaves it alone")

        // Another bench folder's own (main) root: no stale root of the home folder, and the other way round
        // (two Workchats on two bench folders, #2201 T2 review).
        let hub = WorkbenchFolder(id: 5, workbenchID: 7, folderPath: moved.appendingPathComponent("hub").path,
                                  position: 1, name: "hub")
        let hubRoot = CodeRoot(folder: hub, homeFolderID: 3)
        center.markShown(root: hubRoot)
        let hubIndex = center.index(for: hubRoot)
        XCTAssertTrue(center.index(for: root(7)) === mainIndex, "another bench folder leaves the home index alone")
        center.markShown(root: root(7))
        XCTAssertTrue(center.index(for: hubRoot) === hubIndex, "and the home folder leaves the other folder's")

        center.markShown(root: movedRoot)
        XCTAssertFalse(center.index(for: root(7)) === mainIndex, "the stale main index is released")
        XCTAssertTrue(center.index(for: hubRoot) === hubIndex, "a move of the home folder leaves another folder's")
        XCTAssertTrue(center.index(for: worktree) === worktreeIndex, "the worktree's index stays")
    }

    // MARK: Updates

    func testBatchesDebounceIntoOneServeRequestAndABatchDuringARunWaitsAndMerges() async throws {
        let center = makeCenter(["STUB_SERVE_DELAY": "0.6"])
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)

        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), root: root(7))
        try await Task.sleep(for: .milliseconds(100))
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["b.swift", ""]), root: root(7))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(stub.requests, [], "nothing is sent inside the 300 ms window")
        let first = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(first)
        XCTAssertEqual(stub.requests, [["a.swift", "b.swift"]])

        // Request 1 is still running (0.6 s): these wait for it, merged.
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["b.swift"]), root: root(7))
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["c.swift"]), root: root(7))
        let second = await eventually { self.stub.requests.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(stub.requests, [["a.swift", "b.swift"], ["b.swift", "c.swift"]])
        let applied = await eventually { index.symbols(in: "c.swift").map(\.name) == ["r2"] }
        XCTAssertTrue(applied)
        XCTAssertEqual(index.symbols(in: "a.swift").map(\.name), ["r1"])
        XCTAssertEqual(index.symbols(in: "b.swift").map(\.name), ["r2"], "the later request's answer is the one kept")
        XCTAssertEqual(index.files, ["one.swift", "two.swift", "a.swift", "b.swift", "c.swift"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.fullRuns, 1)
    }

    /// A folder written every 200 ms (under the 300 ms debounce) still gets
    /// indexed: the wait is capped at 1 s after the first change. The
    /// debounce runs on a clock the test moves, so only the cap can make a
    /// wait come due between two writes.
    func testContinuousWritesDoNotStarveTheDebounce() async throws {
        let debounceClock = HandMovedDebounceClock()
        let center = makeCenter(debounceClock: debounceClock)
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        let paths = (0 ..< 10).map { "log\($0).swift" }
        for (written, path) in paths.enumerated() {
            center.applyWatcherBatch(FolderWatcher.Batch(paths: [path]), root: root(7))
            await debounceClock.untilSleeps(written + 1) // the write restarted the debounce
            let sent = stub.requests.count
            // A wait that came due goes out before the next write.
            if debounceClock.advance(by: .milliseconds(200)) > 0 {
                let arrived = await eventually { self.stub.requests.count > sent }
                XCTAssertTrue(arrived)
            }
        }
        XCTAssertFalse(stub.requests.isEmpty, "a request went out while the writes went on")
        XCTAssertEqual(stub.requests, [Array(paths[..<5]), Array(paths[5...])], "one request per 1 s cap")
    }

    func testARescanDropsWhatWasDebouncing() async throws {
        let center = makeCenter()
        center.markShown(root: root(7))
        let ready = await eventually { center.index(for: root(7)).state == .ready }
        XCTAssertTrue(ready)
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), root: root(7))
        center.applyWatcherBatch(FolderWatcher.Batch(mustRescan: true), root: root(7))
        let again = await eventually { self.stub.fullRuns == 2 && center.index(for: root(7)).state == .ready }
        XCTAssertTrue(again)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(stub.requests, [], "the full run covered the debounced path")
    }

    func testABatchDuringTheFullRunWaitsForIt() async {
        let center = makeCenter(["STUB_FULL_DELAY": "0.8"])
        center.markShown(root: root(7))
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), root: root(7))
        let sent = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(stub.events, ["full", "request"], "one run per workbench: the update follows the full run")
        let applied = await eventually { center.index(for: root(7)).symbols(in: "a.swift").map(\.name) == ["r1"] }
        XCTAssertTrue(applied)
    }

    /// Ruling R21: a new file of an unsupported language joins the files,
    /// a skipped (git-ignored) one does not, and a listed file that becomes
    /// ignored leaves.
    func testServeRepliesAddUnsupportedFilesAndDropSkippedOnes() async {
        let center = makeCenter(["STUB_FILES": "one.swift dist/old.js"])
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(index.files, ["one.swift", "dist/old.js"])
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["notes.txt", "dist/x.js", "dist/old.js"]), root: root(7))
        let applied = await eventually { index.files == ["one.swift", "notes.txt"] }
        XCTAssertTrue(applied, "files: \(index.files)")
        XCTAssertEqual(index.state, .ready)
    }

    func testRescanRunsAFullIndex() async {
        let center = makeCenter()
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        center.applyWatcherBatch(FolderWatcher.Batch(mustRescan: true), root: root(7))
        let again = await eventually { self.stub.fullRuns == 2 && index.state == .ready }
        XCTAssertTrue(again)
        XCTAssertEqual(stub.requests, [])
    }

    func testAFailingCLIShowsItsStderrAndTheNextShowRetries() async {
        let center = makeCenter(["STUB_FAIL": "reading folder: permission denied"])
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let failed = await eventually { index.state == .failed("reading folder: permission denied") }
        XCTAssertTrue(failed, "state: \(index.state)")
        center.markHidden(root: root(7))
        center.markShown(root: root(7))
        let retried = await eventually { self.stub.fullRuns == 2 }
        XCTAssertTrue(retried)
    }

    func testAMissingCLIFails() {
        let center = CodeIndexCenter(resolveExecutable: { nil }, environment: { [:] }, rulesFile: rulesFile)
        self.center = center
        center.markShown(root: root(7))
        XCTAssertEqual(center.index(for: root(7)).state, .failed("The watchtower command-line tool was not found."))
    }

    // MARK: Wiring

    func testCodeFilesCenterForwardsShowsAndBatches() async {
        let center = makeCenter()
        let files = CodeFilesCenter(
            defaults: UserDefaults(suiteName: "CodeIndexCenterTests-\(UUID().uuidString)") ?? .standard,
            gitRead: { _ in .noRepository }, watchesFolders: false
        )
        files.codeIndex = center
        let project = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": folder.path]))
        files.startWatching(project.mainCodeRoot)
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        files.handle(FolderWatcher.Batch(paths: ["lib"]), root: project.mainCodeRoot)
        let sent = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(stub.requests, [["lib/a.swift", "lib/sub/b.swift"]], "a folder is asked for by its files, hidden names skipped")
        files.stopShowing(project.mainCodeRoot)
        center.releaseIdleIndexes(now: clock.now + 300)
        XCTAssertFalse(center.index(for: root(7)) === index)
    }

    /// The Workchat's production wiring (#2201 T2 review round 3): its lease holds the root in the Files centre with
    /// FILES closed, the centre's batches reach this index, and a duplicate base name joining the index turns a bare
    /// file name plain — no longer coloured, and a click on it opens nothing.
    func testAWorkchatHoldTurnsABareNamePlainWhenADuplicateAppearsWithFilesClosed() async throws {
        let debounceClock = HandMovedDebounceClock()
        let center = makeCenter(["STUB_FILES": "lib/a.swift"], debounceClock: debounceClock)
        let files = CodeFilesCenter(
            defaults: UserDefaults(suiteName: "CodeIndexCenterTests-\(UUID().uuidString)") ?? .standard,
            gitRead: { _ in .noRepository }, watchesFolders: false
        )
        files.codeIndex = center
        let lease = WorkchatIndexLease()
        lease.hold(root(7), in: files)
        defer { lease.release() }
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)

        let highlights = WorkchatHighlights()
        func resolves() -> Bool {
            highlights.resolves("a.swift", messageID: 1, root: root(7), epoch: 0, revision: index.filesRevision,
                                indexFiles: index.files)
        }
        _ = resolves()
        await highlights.lookupsFinished()
        XCTAssertTrue(resolves(), "a unique base name is coloured")

        try "x\n".write(to: folder.appendingPathComponent("lib/sub/a.swift"), atomically: true, encoding: .utf8)
        files.handle(FolderWatcher.Batch(paths: ["lib/sub/a.swift"]), root: root(7))
        await debounceClock.untilSleeps(1)
        debounceClock.advance(by: .milliseconds(300))
        let joined = await eventually { index.files.contains("lib/sub/a.swift") }
        XCTAssertTrue(joined, "files: \(index.files)")
        _ = resolves()
        await highlights.lookupsFinished()
        XCTAssertFalse(resolves(), "ambiguous now: plain")
        let text = "a.swift"
        let span = AgentTextHighlights.Span(range: text.startIndex ..< text.endIndex, kind: .path, text: text)
        let click = await highlights.action(
            for: span, messageID: 1, root: root(7),
            index: .init(files: { index.files }, revision: { index.filesRevision })
        )
        XCTAssertEqual(click, .nothing)
    }

    /// A bench folder retired and then back on the bench (round 4): held again, its index runs in full, so a
    /// file list kept within the idle time is not trusted.
    func testARestoredFolderRunsItsIndexAgain() async {
        let center = makeCenter()
        let files = CodeFilesCenter(
            defaults: UserDefaults(suiteName: "CodeIndexCenterTests-\(UUID().uuidString)") ?? .standard,
            gitRead: { _ in .noRepository }, watchesFolders: false
        )
        files.codeIndex = center
        let hub = WorkbenchFolder(id: 5, workbenchID: 7, folderPath: folder.path, position: 1, name: "hub")
        let removed = WorkbenchFolder(id: 5, workbenchID: 7, folderPath: folder.path, position: 1,
                                      removedAt: "2026-11-24T00:00:00Z", name: "hub")
        let hubRoot = CodeRoot(folder: hub, homeFolderID: 3)
        let lease = WorkchatIndexLease()
        lease.hold(hubRoot, in: files)
        defer { lease.release() }
        let index = center.index(for: hubRoot)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        files.retireRootsOffTheBench([7: BenchFolders(folders: [removed], homeID: 3)])
        lease.hold(hubRoot, in: files)
        let again = await eventually { self.stub.fullRuns == 2 && index.state == .ready }
        XCTAssertTrue(again, "full runs: \(stub.fullRuns)")
    }

    // MARK: Rules file (spec §6.5)

    private func writeRules(_ text: String) throws {
        try text.write(to: rulesFile, atomically: true, encoding: .utf8)
    }

    /// The CLI reads the rules once per process: an edit kills the
    /// `--serve` child (the next update starts one reading the new file)
    /// and reruns the full index; its done lines set and clear the error.
    func testARulesFileChangeRestartsServeAndRunsAFullIndex() async throws {
        try writeRules("invalid: [\n")
        let center = makeCenter()
        center.markShown(root: root(7))
        let index = center.index(for: root(7))
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(index.rulesError, rulesFile.path + ": invalid YAML")
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), root: root(7))
        let served = await eventually { index.symbols(in: "a.swift").map(\.name) == ["r1"] }
        XCTAssertTrue(served)
        XCTAssertEqual(stub.serveStarts.count, 1)
        XCTAssertTrue(stub.serveStarts[0].contains("--rules \(rulesFile.path) --serve"), "pinned: \(stub.serveStarts)")
        let oldServe = try XCTUnwrap(stub.serveStarts.first.flatMap { pid_t($0.split(separator: " ")[1]) })

        try writeRules("# fixed\n")
        let rerun = await eventually { self.stub.fullRuns == 2 && index.state == .ready }
        XCTAssertTrue(rerun)
        XCTAssertNil(index.rulesError, "the full run read the fixed file")
        let killed = await eventually { killpg(oldServe, 0) != 0 }
        XCTAssertTrue(killed, "the --serve child that read the old file is gone")
        XCTAssertEqual(index.symbols(in: "a.swift"), [], "the full run's listing replaced the old answers")

        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["b.swift"]), root: root(7))
        let again = await eventually { index.symbols(in: "b.swift").map(\.name) == ["r1"] }
        XCTAssertTrue(again, "a new --serve child answers (its request 1)")
        XCTAssertEqual(stub.serveStarts.count, 2)
        XCTAssertNil(index.rulesError, "the new child read the fixed file")
    }

    /// Edits inside the debounce (1 s here, for margin) are one reload; a
    /// hidden workbench waits for its next show.
    func testRulesEditsAreDebouncedAndAHiddenWorkbenchReindexesWhenShown() async throws {
        let center = makeCenter(rulesDebounce: .seconds(1))
        center.markShown(root: root(7))
        center.markShown(root: root(8))
        let ready = await eventually { center.index(for: root(7)).state == .ready && center.index(for: root(8)).state == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(stub.fullRuns, 2)
        center.markHidden(root: root(8))

        try writeRules("# one\n")
        try await Task.sleep(for: .milliseconds(200))
        try writeRules("# two\n")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(stub.fullRuns, 2, "still inside the 1 s window of the last edit")
        let reloaded = await eventually { self.stub.fullRuns == 3 && center.index(for: root(7)).state == .ready }
        XCTAssertTrue(reloaded)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(stub.fullRuns, 3, "one reload for both edits, none for the hidden workbench")

        center.markShown(root: root(8))
        let shown = await eventually { self.stub.fullRuns == 4 }
        XCTAssertTrue(shown, "shown again: the full run that waited")
    }

    /// The app creates the rules folder when it starts watching, so a rules
    /// file written after the first show (its folder missing then) is seen.
    func testARulesFileCreatedInAFolderMissingAtTheFirstShowIsApplied() async throws {
        let support = stub.directory.appendingPathComponent("not-yet/Watchtower")
        rulesFile = support.appendingPathComponent("code-languages.yaml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        let center = makeCenter()
        center.markShown(root: root(7))
        let ready = await eventually { center.index(for: root(7)).state == .ready }
        XCTAssertTrue(ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path), "the folder is created to be watched")
        try writeRules("invalid: [\n")
        let applied = await eventually { self.stub.fullRuns == 2 && center.index(for: root(7)).rulesError != nil }
        XCTAssertTrue(applied, "full runs: \(stub.fullRuns)")
    }

    /// A full run in flight read the old rules: it is killed and run again.
    func testARulesChangeDuringAFullRunRestartsIt() async throws {
        let center = makeCenter(["STUB_FULL_DELAY": "30"])
        center.markShown(root: root(7))
        let started = await eventually { self.stub.fullRuns == 1 }
        XCTAssertTrue(started)
        let first = try XCTUnwrap(stub.startedPIDs.first)
        try writeRules("# changed\n")
        let restarted = await eventually { self.stub.fullRuns == 2 && killpg(first, 0) != 0 }
        XCTAssertTrue(restarted)
        XCTAssertEqual(center.index(for: root(7)).state, .indexing(done: 0, total: 0))
    }

    func testPathExpansion() throws {
        let hidden = CodeFileTree.hiddenNames
        XCTAssertEqual(
            CodeIndexPathExpansion.files(for: ["lib", "gone.swift", "lib/a.swift"], in: folder, hidden: hidden, cap: 10),
            ["gone.swift", "lib/a.swift", "lib/sub/b.swift"]
        )
        XCTAssertNil(CodeIndexPathExpansion.files(for: ["lib"], in: folder, hidden: hidden, cap: 1), "over the cap: a full run")
        XCTAssertEqual(CodeIndexPathExpansion.files(for: ["bad\tname"], in: folder, hidden: hidden, cap: 10), [])
    }
}

/// The debounce's clock, moved by hand: `sleep(for:)` returns once
/// `advance(by:)` reaches its deadline, or throws when its task is cancelled
/// (the next batch restarts the debounce). No wall clock.
private final class HandMovedDebounceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var sleepers: [(id: UUID, deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = []
    private var calls = 0
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                calls += 1
                let reached = callWaiters.filter { $0.count <= calls }.map(\.continuation)
                callWaiters.removeAll { $0.count <= calls }
                defer { reached.forEach { $0.resume() } }
                let deadline = current + duration
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append((id, deadline, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index).continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    /// Returns once `sleep(for:)` has been called `count` times in all.
    func untilSleeps(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if calls >= count {
                lock.unlock()
                continuation.resume()
            } else {
                callWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// Moves the clock on and wakes the sleeps that came due; returns how many.
    @discardableResult
    func advance(by duration: Duration) -> Int {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current += duration
            let due = sleepers.filter { $0.deadline <= current }.map(\.continuation)
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        due.forEach { $0.resume() }
        return due.count
    }
}
