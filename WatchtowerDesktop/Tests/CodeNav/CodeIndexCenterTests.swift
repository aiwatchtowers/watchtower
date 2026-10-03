import GRDB
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// `CodeIndexCenter` (spec §7) against a stub CLI: the index survives
/// navigation and is released after 5 idle minutes; watcher batches are
/// debounced into one `--serve` request, a batch during a run waits and
/// merges (Review Focus 3); a rescan is a full run; a failing CLI shows its
/// stderr. Every stub process group is reaped in tearDown.
@MainActor
final class CodeIndexCenterTests: XCTestCase {
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private var stub: CodeCLIStub!
    private var folder: URL!
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
    }

    override func tearDown() async throws {
        center?.stopAll()
        center = nil
        await stub.assertAllGroupsReaped()
        stub.remove()
    }

    private func makeCenter(_ env: [String: String] = [:], executable: String? = nil) -> CodeIndexCenter {
        let path = executable ?? stub.executable.path
        let environment = stub.environment(["STUB_FILES": "one.swift two.swift"].merging(env) { $1 })
        let made = CodeIndexCenter(
            resolveExecutable: { path }, environment: { environment }, clock: { [clock] in clock.now }
        )
        center = made
        return made
    }

    // MARK: Lifetime

    func testNavigatingAwayAndBackKeepsTheIndexAndFiveIdleMinutesReleaseIt() async {
        let center = makeCenter(["STUB_FULL_DELAY": "0.3"])
        center.markShown(workbenchID: 7, folder: folder)
        let index = center.index(for: 7)
        XCTAssertEqual(index.state, .indexing(done: 0, total: 0))
        center.markHidden(workbenchID: 7) // navigated away while it runs
        center.markShown(workbenchID: 7, folder: folder)
        center.markHidden(workbenchID: 7)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(index.files, ["one.swift", "two.swift"])

        clock.now += 299
        center.releaseIdleIndexes()
        center.markShown(workbenchID: 7, folder: folder) // back within 5 minutes
        XCTAssertTrue(center.index(for: 7) === index)
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(stub.fullRuns, 1, "coming back does not reindex")

        center.markHidden(workbenchID: 7)
        clock.now += 299
        center.releaseIdleIndexes()
        XCTAssertTrue(center.index(for: 7) === index)
        clock.now += 1
        center.releaseIdleIndexes()
        let fresh = center.index(for: 7)
        XCTAssertFalse(fresh === index, "released after 5 idle minutes")
        XCTAssertEqual(fresh.state, .idle)
        XCTAssertEqual(fresh.files, [])
    }

    func testReleasingKillsARunInFlight() async {
        let center = makeCenter(["STUB_FULL_DELAY": "30"])
        center.markShown(workbenchID: 7, folder: folder)
        let started = await eventually { self.stub.fullRuns == 1 }
        XCTAssertTrue(started)
        center.markHidden(workbenchID: 7)
        center.releaseIdleIndexes(now: clock.now + 300)
        await stub.assertAllGroupsReaped()
    }

    // MARK: Updates

    func testBatchesDebounceIntoOneServeRequestAndABatchDuringARunWaitsAndMerges() async throws {
        let center = makeCenter(["STUB_SERVE_DELAY": "0.6"])
        center.markShown(workbenchID: 7, folder: folder)
        let index = center.index(for: 7)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)

        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), workbenchID: 7)
        try await Task.sleep(for: .milliseconds(100))
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["b.swift", ""]), workbenchID: 7)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(stub.requests, [], "nothing is sent inside the 300 ms window")
        let first = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(first)
        XCTAssertEqual(stub.requests, [["a.swift", "b.swift"]])

        // Request 1 is still running (0.6 s): these wait for it, merged.
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["b.swift"]), workbenchID: 7)
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["c.swift"]), workbenchID: 7)
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
    /// indexed: the wait is capped at 1 s after the first change.
    func testContinuousWritesDoNotStarveTheDebounce() async throws {
        let center = makeCenter()
        center.markShown(workbenchID: 7, folder: folder)
        let index = center.index(for: 7)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        let paths = (0 ..< 10).map { "log\($0).swift" }
        for path in paths {
            center.applyWatcherBatch(FolderWatcher.Batch(paths: [path]), workbenchID: 7)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(stub.requests.isEmpty, "a request went out while the writes went on")
        let all = await eventually { Set(self.stub.requests.joined()) == Set(paths) }
        XCTAssertTrue(all, "requests: \(stub.requests)")
    }

    func testARescanDropsWhatWasDebouncing() async throws {
        let center = makeCenter()
        center.markShown(workbenchID: 7, folder: folder)
        let ready = await eventually { center.index(for: 7).state == .ready }
        XCTAssertTrue(ready)
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), workbenchID: 7)
        center.applyWatcherBatch(FolderWatcher.Batch(mustRescan: true), workbenchID: 7)
        let again = await eventually { self.stub.fullRuns == 2 && center.index(for: 7).state == .ready }
        XCTAssertTrue(again)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(stub.requests, [], "the full run covered the debounced path")
    }

    func testABatchDuringTheFullRunWaitsForIt() async {
        let center = makeCenter(["STUB_FULL_DELAY": "0.8"])
        center.markShown(workbenchID: 7, folder: folder)
        center.applyWatcherBatch(FolderWatcher.Batch(paths: ["a.swift"]), workbenchID: 7)
        let sent = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(stub.events, ["full", "request"], "one run per workbench: the update follows the full run")
        let applied = await eventually { center.index(for: 7).symbols(in: "a.swift").map(\.name) == ["r1"] }
        XCTAssertTrue(applied)
    }

    func testRescanRunsAFullIndex() async {
        let center = makeCenter()
        center.markShown(workbenchID: 7, folder: folder)
        let index = center.index(for: 7)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        center.applyWatcherBatch(FolderWatcher.Batch(mustRescan: true), workbenchID: 7)
        let again = await eventually { self.stub.fullRuns == 2 && index.state == .ready }
        XCTAssertTrue(again)
        XCTAssertEqual(stub.requests, [])
    }

    func testAFailingCLIShowsItsStderrAndTheNextShowRetries() async {
        let center = makeCenter(["STUB_FAIL": "reading folder: permission denied"])
        center.markShown(workbenchID: 7, folder: folder)
        let index = center.index(for: 7)
        let failed = await eventually { index.state == .failed("reading folder: permission denied") }
        XCTAssertTrue(failed, "state: \(index.state)")
        center.markHidden(workbenchID: 7)
        center.markShown(workbenchID: 7, folder: folder)
        let retried = await eventually { self.stub.fullRuns == 2 }
        XCTAssertTrue(retried)
    }

    func testAMissingCLIFails() {
        let center = CodeIndexCenter(resolveExecutable: { nil }, environment: { [:] })
        self.center = center
        center.markShown(workbenchID: 7, folder: folder)
        XCTAssertEqual(center.index(for: 7).state, .failed("The watchtower command-line tool was not found."))
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
        files.startWatching(project)
        let index = center.index(for: 7)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready)
        files.handle(FolderWatcher.Batch(paths: ["lib"]), projectID: 7)
        let sent = await eventually { !self.stub.requests.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(stub.requests, [["lib/a.swift", "lib/sub/b.swift"]], "a folder is asked for by its files, hidden names skipped")
        files.stopShowing(project)
        center.releaseIdleIndexes(now: clock.now + 300)
        XCTAssertFalse(center.index(for: 7) === index)
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
