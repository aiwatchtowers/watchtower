import Foundation
@testable import WatchtowerCore
import XCTest

@MainActor
final class DatabaseCompactionStepTests: XCTestCase {
    private let calls = Recorder()
    private let logs = Recorder()
    private let sleeper = FakeSleeper()
    private let child = FakeChild()

    override func tearDown() async throws {
        // A child the test left running exits, so no run task stays parked.
        child.exit(status: 0)
        sleeper.releaseAll()
    }

    // MARK: - Flow

    func testNotDueRunsNothing() async {
        let step = makeStep(check: .success(.fixture(due: false)))
        await step.run { "/db" }
        XCTAssertEqual(calls.items, ["check"])
        XCTAssertFalse(step.stoppedDaemon)
        XCTAssertEqual(step.phase, .finished)
        XCTAssertNil(step.notice)
    }

    func testDiskShortShowsNoticeAndSkips() async {
        let step = makeStep(check: .success(.fixture(
            diskOk: false, freeDiskBytes: 2_000_000_000, needsDiskBytes: 4_400_000_000
        )))
        await step.run { "/db" }
        XCTAssertEqual(calls.items, ["check"])
        XCTAssertEqual(step.phase, .finished)
        let needs = ByteCountFormatter.string(fromByteCount: 4_400_000_000, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file)
        XCTAssertEqual(
            step.notice,
            "Watchtower could not optimize its database: it needs \(needs) free, \(available) available."
        )
        XCTAssertEqual(
            DatabaseCompactionStep.diskNotice(needs: 4_400_000_000, available: 2_000_000_000, size: enUS),
            "Watchtower could not optimize its database: it needs 4.4 GB free, 2 GB available."
        )
    }

    func testDueStopsDaemonThenCompactsInOrder() async {
        let step = makeStep(check: .success(.fixture(dbBytes: 2_000_000_000)))
        let run = Task { await step.run { "/db" } }
        await until { step.phase != .idle && step.phase != .checking }
        XCTAssertEqual(step.phase, .compacting(dbBytes: 2_000_000_000))
        XCTAssertTrue(step.stoppedDaemon)
        XCTAssertTrue(step.isRunning)
        XCTAssertEqual(calls.items, ["check", "stopDaemon", "startCompact"])
        child.exit(status: 0, stdout: #"{"compacted":true,"reason":"migration:134","bytes_before":10,"bytes_after":5,"duration_ms":7}"#)
        await run.value
        XCTAssertEqual(step.phase, .finished)
        XCTAssertFalse(step.isRunning)
        XCTAssertNil(step.notice)
    }

    func testCheckFailureContinues() async {
        let step = makeStep(check: .failure(URLError(.cannotOpenFile)))
        await step.run { "/db" }
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(calls.items, ["check"])
        XCTAssertEqual(logs.items.filter { $0.contains("compaction check") }.count, 1)
    }

    func testResolveDBPathFailureCallsNoCLI() async {
        let step = makeStep(check: .success(.fixture()))
        await step.run { throw URLError(.fileDoesNotExist) }
        XCTAssertEqual(calls.items, [])
        XCTAssertEqual(step.phase, .finished)
    }

    func testStartFailureContinues() async {
        let step = makeStep(check: .success(.fixture()), startFails: true)
        await step.run { "/db" }
        XCTAssertEqual(calls.items, ["check", "stopDaemon", "startCompact"])
        XCTAssertEqual(step.phase, .finished)
        XCTAssertTrue(logs.items.contains { $0.contains("could not start") })
    }

    // MARK: - Skip

    func testSkipHiddenBefore15Seconds() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        await tick(14, step)
        XCTAssertEqual(step.elapsedSeconds, 14)
        XCTAssertFalse(step.canSkip)
        step.skip()
        XCTAssertEqual(child.terminateCount, 0, "Skip before 15 s does nothing")
        await tick(1, step)
        XCTAssertTrue(step.canSkip)
        child.exit(status: 0)
        await run.value
        XCTAssertFalse(step.canSkip)
    }

    /// Skip lands between ticks: ten ticks after it may be under 10 s, so the
    /// SIGKILL waits for the eleventh — strictly more than the threshold.
    func testSkipTerminatesThenKillsAfterMoreThan10Seconds() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        await tick(15, step)
        step.skip()
        XCTAssertEqual(child.terminateCount, 1)
        XCTAssertFalse(step.canSkip)
        await tick(DatabaseCompactionStep.killAfterSkipSeconds, step)
        XCTAssertEqual(child.killCount, 0)
        await tick(1, step)
        XCTAssertEqual(child.killCount, 1)
        child.exit(status: 9)
        await run.value
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(child.killCount, 1)
    }

    func testSecondRunIsANoOp() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        // While the first run compacts…
        await step.run { "/db" }
        XCTAssertEqual(calls.items.filter { $0 == "check" }.count, 1)
        child.exit(status: 0, stdout: #"{"compacted":true}"#)
        await run.value
        // …and once it has finished.
        await step.run { "/db" }
        XCTAssertEqual(calls.items, ["check", "stopDaemon", "startCompact"])
        XCTAssertEqual(step.phase, .finished)
    }

    func testUndecodableResultLineIsLogged() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 1, stdout: "not json")
        await run.value
        XCTAssertTrue(logs.items.contains { $0.hasPrefix("DB compaction: no result line (exit 1)") }, "\(logs.items)")
        XCTAssertTrue(logs.items.contains { $0.hasPrefix("DB compaction failed") })
    }

    func testSkipChildExitsOnTerminateNoKill() async {
        child.exitsOnTerminate = true
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        await tick(15, step)
        step.skip()
        await run.value
        XCTAssertEqual(child.terminateCount, 1)
        XCTAssertEqual(child.killCount, 0)
        XCTAssertEqual(step.phase, .finished)
        XCTAssertNil(step.notice)
    }

    // MARK: - Exits

    func testGaveUpShowsNoticeOnce() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 1, stdout: #"{"compacted":false,"error":"disk I/O error","failures":3,"gave_up":true}"#)
        await run.value
        XCTAssertEqual(step.notice, DatabaseCompactionStep.gaveUpNotice)
        step.dismissNotice()
        XCTAssertNil(step.notice)
    }

    func testFailureWithoutGiveUpLogsOnly() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 1, stdout: #"{"compacted":false,"error":"disk I/O error","failures":1,"gave_up":false}"#)
        await run.value
        XCTAssertNil(step.notice)
        XCTAssertTrue(logs.items.contains { $0.contains("disk I/O error") })
    }

    func testDiskExitShowsNoticeFromCheck() async {
        let step = makeStep(check: .success(.fixture(freeDiskBytes: 9_000, needsDiskBytes: 8_000)))
        let run = await startCompacting(step)
        child.exit(status: 2, stdout: #"{"compacted":false,"skipped":"disk"}"#)
        await run.value
        XCTAssertEqual(step.notice, DatabaseCompactionStep.diskNotice(needs: 8_000, available: 9_000))
    }

    func testDaemonRunningExitContinues() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 3, stdout: #"{"compacted":false,"skipped":"daemon_running"}"#)
        await run.value
        XCTAssertEqual(step.phase, .finished)
        XCTAssertNil(step.notice)
        XCTAssertTrue(logs.items.contains { $0.contains("daemon") })
    }

    func testTerminateForQuit() async {
        let step = makeStep(check: .success(.fixture()))
        await step.terminateForQuit()
        let run = await startCompacting(step)
        let quit = Task { await step.terminateForQuit() }
        await until { self.child.terminateCount == 1 }
        child.exit(status: 4)
        await quit.value
        await run.value
        XCTAssertEqual(child.killCount, 0, "the child exited within the grace")
        await step.terminateForQuit()
        XCTAssertEqual(child.terminateCount, 1, "no-op once the child has exited")
    }

    /// A child still alive `quitGrace` after the quit's SIGTERM gets SIGKILL,
    /// and the quit returns.
    func testQuitKillsChildThatIgnoresTerminate() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        let quit = Task { await step.terminateForQuit() }
        // The ticker's sleep and the grace's.
        await until { self.child.terminateCount == 1 && self.sleeper.pendingCount == 2 }
        XCTAssertEqual(child.killCount, 0)
        sleeper.releaseAll()
        await quit.value
        XCTAssertEqual(child.killCount, 1)
        XCTAssertTrue(logs.items.contains { $0.contains("did not exit") }, "\(logs.items)")
        child.exit(status: 9, reason: .uncaughtSignal)
        await run.value
        XCTAssertEqual(step.phase, .finished)
    }

    /// The daemon stop runs through `serializeDaemonStop` (the app's start
    /// queue).
    func testDaemonStopRunsThroughSerializer() async {
        let step = makeStep(check: .success(.fixture()))
        let calls = calls
        step.serializeDaemonStop = { stop in
            calls.append("queued")
            await stop()
        }
        let run = await startCompacting(step)
        XCTAssertEqual(calls.items, ["check", "queued", "stopDaemon", "startCompact"])
        child.exit(status: 0)
        await run.value
    }

    func testQuitDuringCheckCancelsItAndStartsNothing() async {
        let parked = ParkedCheck()
        let step = makeStep(check: .success(.fixture()), parkedCheck: parked)
        let run = Task { await step.run { "/db" } }
        await until { parked.isParked }
        XCTAssertTrue(step.isRunning)
        await step.terminateForQuit()
        await run.value
        XCTAssertTrue(parked.wasCancelled, "the check's task is cancelled, which terminates its child")
        XCTAssertTrue(logs.items.contains("DB compaction check cancelled by quit"), "\(logs.items)")
        XCTAssertEqual(calls.items, ["check"], "no daemon stop, no compact after a quit")
        XCTAssertEqual(step.phase, .finished)
    }

    func testQuitDuringDaemonStopStartsNoCompact() async {
        let calls = calls
        let box = StepBox()
        let step = DatabaseCompactionStep(
            cli: FakeCompactionCLI(calls: calls, result: .success(.fixture()), child: child, startFails: false),
            stopDaemon: { @MainActor in
                calls.append("stopDaemon")
                await box.step?.terminateForQuit()
            },
            sleep: { _ in },
            log: { _ in }
        )
        box.step = step
        await step.run { "/db" }
        XCTAssertEqual(calls.items, ["check", "stopDaemon"])
        XCTAssertEqual(step.phase, .finished)
    }

    func testSignalExitLogsSignal() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 9, reason: .uncaughtSignal, stderr: "partial")
        await run.value
        XCTAssertTrue(logs.items.contains { $0.contains("killed by signal 9") && $0.contains("partial") }, "\(logs.items)")
        XCTAssertNil(step.notice)
    }

    /// Exit 2 without a `disk` result line is not the disk skip: no notice,
    /// stderr logged.
    func testExit2WithoutDiskSkipShowsNoNotice() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 2, stderr: "flag parse error")
        await run.value
        XCTAssertNil(step.notice)
        XCTAssertTrue(logs.items.contains { $0.contains("exit status 2") && $0.contains("flag parse error") }, "\(logs.items)")
    }

    func testExit4WithoutInterruptedSkipLogsStderr() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 4, stdout: #"{"compacted":false,"skipped":"disk"}"#, stderr: "odd")
        await run.value
        XCTAssertNil(step.notice)
        XCTAssertTrue(logs.items.contains { $0.contains("exit status 4") && $0.contains("odd") }, "\(logs.items)")
    }

    func testExit0WithoutResultLineLogsStderr() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 0, stderr: "warning: something")
        await run.value
        XCTAssertTrue(logs.items.contains { $0.contains("exit 0 without a result line") && $0.contains("warning: something") })
    }

    func testCheckpointBusyIsLogged() async {
        let step = makeStep(check: .success(.fixture()))
        let run = await startCompacting(step)
        child.exit(status: 0, stdout: #"{"compacted":true,"bytes_before":10,"bytes_after":9,"checkpoint_busy":true}"#)
        await run.value
        XCTAssertTrue(logs.items.contains { $0.contains("reclaimed at the next checkpoint") }, "\(logs.items)")
    }

    // MARK: - Strings

    func testElapsedText() {
        XCTAssertEqual(DatabaseCompactionStep.elapsedText(seconds: 42), "0:42")
        XCTAssertEqual(DatabaseCompactionStep.elapsedText(seconds: 65), "1:05")
        XCTAssertEqual(DatabaseCompactionStep.elapsedText(seconds: 0), "0:00")
        XCTAssertEqual(DatabaseCompactionStep.elapsedText(seconds: 600), "10:00")
    }

    func testProgressLine() {
        XCTAssertEqual(
            DatabaseCompactionStep.progressLine(dbBytes: 2_000_000_000, elapsedSeconds: 42, size: enUS),
            "Optimizing database — 2 GB, 0:42"
        )
        let size = ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file)
        XCTAssertEqual(
            DatabaseCompactionStep.progressLine(dbBytes: 2_000_000_000, elapsedSeconds: 42),
            "Optimizing database — \(size), 0:42"
        )
    }

    func testDecodesLastJSONLineAfterPreamble() throws {
        let stdout = Data(#"""
        schema format upgraded
        {"due":false,"reason":"","db_bytes":1,"wal_bytes":2,"free_disk_bytes":3,"needs_disk_bytes":4,"disk_ok":true}


        """#.utf8)
        let check = try decodeLastJSONLine(CompactionCheck.self, from: stdout)
        XCTAssertEqual(check, CompactionCheck(
            due: false, reason: "", dbBytes: 1, walBytes: 2, freeDiskBytes: 3, needsDiskBytes: 4, diskOk: true
        ))
        XCTAssertThrowsError(try decodeLastJSONLine(CompactionCheck.self, from: Data("schema format upgraded\n".utf8)))
        XCTAssertThrowsError(try decodeLastJSONLine(CompactionCheck.self, from: Data("\n\n".utf8)))

        let notDue = try decodeLastJSONLine(
            CompactionRunOutput.self, from: Data(#"{"compacted":false,"skipped":"not_due"}"#.utf8)
        )
        XCTAssertEqual(notDue.skipped, "not_due")
        XCTAssertFalse(notDue.gaveUp, "an absent gave_up decodes as false")
    }

    // MARK: - Helpers

    private func enUS(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
    }

    private func makeStep(
        check: Result<CompactionCheck, Error>,
        startFails: Bool = false,
        parkedCheck: ParkedCheck? = nil
    ) -> DatabaseCompactionStep {
        let cli = FakeCompactionCLI(
            calls: calls, result: check, child: child, startFails: startFails, parkedCheck: parkedCheck
        )
        let calls = calls
        let sleeper = sleeper
        let logs = logs
        return DatabaseCompactionStep(
            cli: cli,
            stopDaemon: { calls.append("stopDaemon") },
            sleep: { _ in await sleeper.sleep() },
            log: { logs.append($0) }
        )
    }

    /// Starts `run` and returns once the step is compacting and its ticker
    /// waits on the first sleep.
    private func startCompacting(_ step: DatabaseCompactionStep) async -> Task<Void, Never> {
        let run = Task { await step.run { "/db" } }
        await until { step.phase != .idle && step.phase != .checking && self.sleeper.pendingCount == 1 }
        return run
    }

    /// Lets `n` one-second sleeps elapse, each fully processed by the step.
    private func tick(_ n: Int, _ step: DatabaseCompactionStep) async {
        for _ in 0..<n {
            let before = step.elapsedSeconds
            sleeper.releaseOne()
            await until { step.elapsedSeconds == before + 1 && self.sleeper.pendingCount == 1 }
        }
    }

    /// Yields the main actor until `condition` holds; fails after a bounded
    /// number of turns rather than hanging.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held", file: file, line: line)
    }
}

// MARK: - Fakes

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var items: [String] { lock.withLock { stored } }
    func append(_ item: String) { lock.withLock { stored.append(item) } }
}

private struct FakeCompactionCLI: CompactionCLI {
    struct StartFailed: Error {}
    let calls: Recorder
    let result: Result<CompactionCheck, Error>
    let child: FakeChild
    let startFails: Bool
    var parkedCheck: ParkedCheck?

    func check() async throws -> CompactionCheck {
        calls.append("check")
        if let parkedCheck {
            await parkedCheck.park()
            try Task.checkCancellation()
        }
        return try result.get()
    }

    func startCompact() throws -> any CompactionChild {
        calls.append("startCompact")
        if startFails { throw StartFailed() }
        return child
    }
}

/// A `db compact` child that exits when the test says (or on terminate, when
/// `exitsOnTerminate`).
private final class FakeChild: CompactionChild, @unchecked Sendable {
    private let lock = NSLock()
    private var result: CompactionExit?
    private var waiter: CheckedContinuation<CompactionExit, Never>?
    private var terminates = 0
    private var kills = 0
    private var exitOnTerminate = false

    var terminateCount: Int { lock.withLock { terminates } }
    var killCount: Int { lock.withLock { kills } }
    var exitsOnTerminate: Bool {
        get { lock.withLock { exitOnTerminate } }
        set { lock.withLock { exitOnTerminate = newValue } }
    }

    func terminate() {
        let exits = lock.withLock { terminates += 1; return exitOnTerminate }
        if exits { exit(status: 4, stdout: #"{"compacted":false,"skipped":"interrupted"}"#) }
    }

    func kill() {
        lock.withLock { kills += 1 }
    }

    func exit(
        status: Int32,
        reason: Process.TerminationReason = .exit,
        stdout: String = "",
        stderr: String = ""
    ) {
        let resume: CheckedContinuation<CompactionExit, Never>?
        let exit = CompactionExit(status: status, reason: reason, stdout: Data(stdout.utf8), stderr: stderr)
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        result = exit
        resume = waiter
        waiter = nil
        lock.unlock()
        resume?.resume(returning: exit)
    }

    func waitForExit() async -> CompactionExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

@MainActor
private final class StepBox {
    var step: DatabaseCompactionStep?
}

/// A `--check` that answers only once its task is cancelled.
private final class ParkedCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var cancelled = false

    var isParked: Bool { lock.withLock { waiter != nil } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelled { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                cancelled = true
                defer { waiter = nil }
                return waiter
            }
            parked?.resume()
        }
    }
}

/// A one-second sleep that returns only when the test releases it.
private final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { lock.withLock { pending.count } }

    func sleep() async {
        await withCheckedContinuation { continuation in
            lock.withLock { pending.append(continuation) }
        }
    }

    func releaseOne() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.resume()
    }

    func releaseAll() {
        let all = lock.withLock { defer { pending = [] }; return pending }
        all.forEach { $0.resume() }
    }
}

private extension CompactionCheck {
    static func fixture(
        due: Bool = true,
        dbBytes: Int64 = 1_000,
        diskOk: Bool = true,
        freeDiskBytes: Int64 = 10_000,
        needsDiskBytes: Int64 = 2_000
    ) -> CompactionCheck {
        CompactionCheck(
            due: due, reason: due ? "migration:134" : "", dbBytes: dbBytes, walBytes: 0,
            freeDiskBytes: freeDiskBytes, needsDiskBytes: needsDiskBytes, diskOk: diskOk
        )
    }
}
