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
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var released = false
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0

    /// Returns once `count` rescans have started: the event, not a clock.
    func untilStarted(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = lock.withLock {
                if started < count { startWaiters.append((count, continuation)) }
                return started >= count
            }
            if reached { continuation.resume() }
        }
    }

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["automations", "rescan"]) else { return Data() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started += 1
            let reached = startWaiters.filter { $0.count <= started }.map(\.continuation)
            startWaiters.removeAll { $0.count <= started }
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
            reached.forEach { $0.resume() }
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

/// A one-way gate: every wait parks until `open()`, and none after it.
private final class OpenOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return !isOpen
            }
            if !parked { continuation.resume() }
        }
    }

    func open() {
        let parked = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        parked.forEach { $0.resume() }
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

    /// The workbench's main root, watched as FILES would watch it.
    private func watchedRoot(_ vm: WorkbenchesViewModel, id: Int64) -> CodeRoot {
        let root = CodeRoot(main: Workbench(row: Row(["id": id, "name": "acme", "folder_path": folder.path])))
        vm.codeFiles.startWatching(root)
        return root
    }

    func testRescanOnPageOpen() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationsReady = { true }

        vm.workbenchPageOpened(projectID: 7)

        await vm.automationRescansSettled()
        XCTAssertEqual(rescans(runner), [["automations", "rescan", "--workbench", "7"]])
    }

    func testRescanOnRecipeFolderChangeDebounced() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationsReady = { true }
        // The settle wait is opened by hand: no clock decides which batch
        // lands inside it.
        let settle = OpenOnceGate()
        vm.automationRescanSleep = { _ in await settle.wait() }
        let root = watchedRoot(vm, id: 7)

        // Three batches before the changes settle.
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/digest.md"]), root: root)
        let first = try XCTUnwrap(vm.automationRescanTimers[7])
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/review.md"]), root: root)
        let second = try XCTUnwrap(vm.automationRescanTimers[7])
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations"]), root: root)
        let last = try XCTUnwrap(vm.automationRescanTimers[7])
        XCTAssertTrue(first.isCancelled && second.isCancelled, "each batch restarts the wait")
        XCTAssertFalse(last.isCancelled)
        XCTAssertTrue(rescans(runner).isEmpty, "nothing runs before the batches settle")

        settle.open()
        await first.value
        await second.value
        await last.value
        await vm.automationRescansSettled()
        XCTAssertEqual(rescans(runner), [["automations", "rescan", "--workbench", "7"]], "one rescan for the three batches")
        XCTAssertTrue(vm.automationRescansAgain.isEmpty, "no second rescan queued behind it")
    }

    func testNoRescanForOtherPaths() async throws {
        let runner = FakeCLIRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationsReady = { true }
        let root = watchedRoot(vm, id: 7)

        vm.codeFiles.handle(FolderWatcher.Batch(paths: ["Makefile", "docs/automations/notes.md",
                                                        ".watchtower/automations-old/x.md", ".watchtower/state.json"]),
                            root: root)
        vm.codeFiles.handle(FolderWatcher.Batch(gitChanged: true), root: root)
        // A worktree's copy is not the workbench's folder Go indexes.
        let worktree = CodeRoot(workbenchID: 7, worktree: folder)
        vm.codeFiles.startWatching(worktree)
        vm.codeFiles.handle(FolderWatcher.Batch(paths: [".watchtower/automations/digest.md"]), root: worktree)

        // A batch schedules its rescan as it is handled: none was, so none
        // can run later.
        XCTAssertTrue(vm.automationRescanTimers.isEmpty, "no rescan was scheduled")
        XCTAssertTrue(rescans(runner).isEmpty)
    }

    /// House rule: the rescan belongs to the AppState-owned view model, so
    /// leaving the page (and the tab) neither cancels one in flight nor
    /// loses it; coming back opens the page again, which rescans again.
    func testRescanSurvivesNavigation() async throws {
        let runner = GatedRescanRunner()
        let appState = AppState()
        appState.featureVisibility.isLoaded = true
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
                                 sessionNotifier: RecordingSessionNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        defer { vm.asks.stop() }
        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = 7
        vm.workbenchPageOpened(projectID: 7)
        await runner.untilStarted(1)

        appState.selectedDestination = .inbox
        vm.selectedWorkbenchID = nil
        runner.release()
        await vm.automationRescansSettled()
        XCTAssertEqual(runner.finished, 1)
        XCTAssertEqual(runner.cancelled, 0, "navigation does not cancel the rescan")

        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = 7
        XCTAssertTrue(appState.workbenchesViewModel === vm)
        vm.workbenchPageOpened(projectID: 7)
        await vm.automationRescansSettled()
        XCTAssertEqual(runner.finished, 2)
    }

    /// Before the Feature Manager's first successful load (or after a
    /// failed one), no rescan runs: the pages opened meanwhile are
    /// rescanned once each when the features list loads.
    func testRescansAskedBeforeTheFeaturesLoadRunWhenTheyDo() async throws {
        let runner = FakeCLIRunner()
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
                                 sessionNotifier: RecordingSessionNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        defer { stopWiring(appState) }

        vm.workbenchPageOpened(projectID: 7)
        // Not loaded (or the load failed): the sync changes nothing.
        appState.featureVisibility.isLoaded = false
        appState.syncAutomationSessionCenter()
        vm.workbenchPageOpened(projectID: 9)
        // A rescan starts (in flight) as it is asked for, or waits: these wait.
        XCTAssertEqual(vm.automationRescansDeferred, [7, 9])
        XCTAssertTrue(vm.automationRescansInFlight.isEmpty, "not loaded")
        XCTAssertTrue(rescans(runner).isEmpty, "not loaded")

        // Loaded: each waiting workbench once.
        appState.featureVisibility.isLoaded = true
        appState.syncAutomationSessionCenter()
        await vm.automationRescansSettled()
        XCTAssertEqual(rescans(runner).count, 2)
        XCTAssertEqual(Set(rescans(runner).map { $0.last }), ["7", "9"])
        appState.syncAutomationSessionCenter()
        XCTAssertTrue(vm.automationRescansInFlight.isEmpty, "a later load rescans nothing again")
        XCTAssertEqual(rescans(runner).count, 2, "a later load rescans nothing again")

        vm.workbenchPageOpened(projectID: 7)
        await vm.automationRescansSettled()
        XCTAssertEqual(rescans(runner).count, 3)
    }

    private func stopWiring(_ appState: AppState) {
        appState.automationSessionCenter?.stop()
        appState.sessionReportCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
        appState.workbenchNotificationCenter?.stop()
        appState.workbenchesViewModel?.asks.stop()
        appState.ownerPresenceCenter?.stop()
    }

    /// One rescan per workbench at a time: asks while it runs collapse into
    /// one follow-up after it; another workbench is not held up.
    func testRescanInFlightIsNotDuplicated() async throws {
        let runner = GatedRescanRunner()
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.automationsReady = { true }

        vm.workbenchPageOpened(projectID: 7)
        await runner.untilStarted(1)
        vm.workbenchPageOpened(projectID: 7)
        vm.workbenchPageOpened(projectID: 7)
        vm.workbenchPageOpened(projectID: 8)
        await runner.untilStarted(2)
        // The asks are booked as they are made: nothing else is on its way.
        XCTAssertEqual(vm.automationRescansInFlight, [7, 8])
        XCTAssertEqual(vm.automationRescansAgain, [7], "the two asks on workbench 7 wait as one")
        XCTAssertEqual(runner.started, 2, "workbench 7 once, workbench 8 once")

        runner.release()
        await vm.automationRescansSettled()
        XCTAssertEqual(runner.finished, 3)
        XCTAssertTrue(vm.automationRescansInFlight.isEmpty)
        XCTAssertTrue(vm.automationRescansAgain.isEmpty)
        XCTAssertEqual(runner.started, 3, "one follow-up for the two asks on workbench 7")
    }
}
