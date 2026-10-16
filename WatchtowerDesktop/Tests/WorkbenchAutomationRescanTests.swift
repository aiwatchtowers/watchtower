import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A runner whose `automations rescan` calls wait for `release()`, noting
/// whether the calling task was cancelled meanwhile; every other call
/// returns at once.
private final class GatedRescanRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["automations", "rescan"]) else { return Data() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
        lock.lock()
        if Task.isCancelled { cancelled += 1 } else { finished += 1 }
        lock.unlock()
        return Data()
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// `automations rescan --workbench N` (spec §13.4, ruling R-P5-9): run for
/// every workbench page opened, and after the page's folder watcher sees a
/// change under `.watchtower/automations/`, debounced.
@MainActor
final class WorkbenchAutomationRescanTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchAutomationRescanTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt rescan \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func rescans(_ runner: FakeCLIRunner) -> [[String]] {
        runner.invocations.filter { $0.starts(with: ["automations", "rescan"]) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met in time")
    }

    /// The workbench's main root, watched as FILES would watch it.
    private func watchedRoot(_ vm: WorkbenchesViewModel, id: Int64) -> CodeRoot {
        let root = CodeRoot(main: Workbench(row: Row(["id": id, "name": "acme", "folder_path": folder.path])))
        vm.codeFiles.startWatching(root)
        return root
    }

    func testRescanOnPageOpen() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)

        vm.workbenchPageOpened(projectID: 7)

        await waitUntil { self.rescans(runner).count == 1 }
        XCTAssertEqual(rescans(runner), [["automations", "rescan", "--workbench", "7"]])
    }

    func testRescanOnRecipeFolderChangeDebounced() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationRescanDelay = .milliseconds(400)
        let root = watchedRoot(vm, id: 7)

        // Three batches within 300 ms.
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/digest.md"]), root: root)
        try await Task.sleep(for: .milliseconds(100))
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/review.md"]), root: root)
        try await Task.sleep(for: .milliseconds(100))
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations"]), root: root)
        XCTAssertTrue(rescans(runner).isEmpty, "nothing runs before the batches settle")

        await waitUntil { self.rescans(runner).count == 1 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rescans(runner), [["automations", "rescan", "--workbench", "7"]], "one rescan for the three batches")
    }

    func testNoRescanForOtherPaths() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationRescanDelay = .milliseconds(50)
        let root = watchedRoot(vm, id: 7)

        vm.codeFiles.handle(FolderWatcher.Batch(paths: ["Makefile", "docs/automations/notes.md",
                                                        ".watchtower/automations-old/x.md", ".watchtower/state.json"]),
                            root: root)
        vm.codeFiles.handle(FolderWatcher.Batch(gitChanged: true), root: root)
        // A worktree's copy is not the workbench's folder Go indexes.
        let worktree = CodeRoot(workbenchID: 7, worktree: folder)
        vm.codeFiles.startWatching(worktree)
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/digest.md"]), root: worktree)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rescans(runner).isEmpty)
    }

    /// House rule: the rescan belongs to the AppState-owned view model, so
    /// leaving the page (and the tab) neither cancels one in flight nor
    /// loses it; coming back opens the page again, which rescans again.
    func testRescanSurvivesNavigation() async throws {
        let runner = GatedRescanRunner()
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
                                 sessionNotifier: RecordingSessionNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        defer { vm.asks.stop() }
        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = 7
        vm.workbenchPageOpened(projectID: 7)
        await waitUntil { runner.started == 1 }

        appState.selectedDestination = .inbox
        vm.selectedWorkbenchID = nil
        runner.release()
        await waitUntil { runner.finished == 1 }
        XCTAssertEqual(runner.cancelled, 0, "navigation does not cancel the rescan")

        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = 7
        XCTAssertTrue(appState.workbenchesViewModel === vm)
        vm.workbenchPageOpened(projectID: 7)
        await waitUntil { runner.finished == 2 }
    }
}
