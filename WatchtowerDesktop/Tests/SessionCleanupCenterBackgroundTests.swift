import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A deleted session's background apply in `SessionCleanupCenter` (board
/// #1716, spec 2026-11-10 §1, §4): its exit decides with its `done`, the
/// quit spawns nothing after it, and the slot is freed only once the child
/// was reaped. No subprocess is spawned: the CLI is a scripted streamer.
@MainActor
final class SessionCleanupCenterBackgroundTests: XCTestCase {
    private var streamer: ScriptedCleanupStreamer!
    private var center: SessionCleanupCenter!

    override func setUp() async throws {
        streamer = ScriptedCleanupStreamer()
        center = SessionCleanupCenter(runner: nil, streamer: streamer)
        center.baseEnvironment = { [:] }
    }

    override func tearDown() async throws {
        streamer.finishAll()
        streamer = nil
        center = nil
    }

    private static let cleanDone = CleanupStreamFixture.doneApply(
        #"{"key":"branch:feat/a","kind":"branch","name":"feat/a","action":"remove","done":true}"#
    )

    private func started() async -> ScriptedCleanupStreamer.Run? {
        await waitUntil("the apply started") { !self.streamer.runs.isEmpty }
        return streamer.runs.first
    }

    func testNonzeroExitAfterDoneIsCouldNot() async throws {
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        let run = try await XCTUnwrapAsync(await started())
        run.send(Self.cleanDone)
        run.finish(status: 1, message: "watchtower exited with code 1")

        let result = await apply.value

        XCTAssertNotNil(result.result)
        XCTAssertEqual(result.runError, "watchtower exited with code 1")
        guard case .notFullyCleaned = SessionAutoCleanupOutcome.evaluate(
            result: result.result, title: "T", runError: result.runError
        ) else { return XCTFail("a failed exit after done is never clean") }
    }

    func testChildThatDoesNotExitAfterDoneIsStoppedAndIsCouldNot() async throws {
        center.exitAfterDoneLimit = .milliseconds(20)
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        let run = try await XCTUnwrapAsync(await started())
        run.send(Self.cleanDone)

        let result = await apply.value

        XCTAssertEqual(run.groupStopGraces, [.seconds(5)], "its group is stopped")
        XCTAssertNotNil(result.runError, "a stopped child is never a clean outcome")
    }

    func testCleanExitAfterDoneIsClean() async throws {
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        let run = try await XCTUnwrapAsync(await started())
        run.send(Self.cleanDone)
        run.finish(status: 0)

        let result = await apply.value

        XCTAssertNil(result.runError)
        XCTAssertEqual(result.result?.items.first?.done, true)
    }

    /// The slot stays taken after `done` until the child was reaped.
    func testSlotIsFreedOnlyOnceTheChildWasReaped() async throws {
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        let run = try await XCTUnwrapAsync(await started())
        run.send(Self.cleanDone)
        var next = false
        let waiter = Task {
            await center.acquireSlot(workbenchID: 2)
            next = true
            center.releaseSlot(workbenchID: 2)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(next, "done alone does not free the slot")

        run.finish(status: 0)
        _ = await apply.value
        await waiter.value
        XCTAssertTrue(next)
    }

    /// The quit runs while the apply waits for its environment: nothing is
    /// spawned after it.
    func testQuitDuringTheEnvironmentWaitSpawnsNothing() async throws {
        let gate = EnvironmentGate()
        center.baseEnvironment = { await gate.wait() }
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        await gate.untilWaiting()

        await center.stopBackgroundApplies()
        gate.open()
        let result = await apply.value

        XCTAssertTrue(streamer.runs.isEmpty, "no child after the quit")
        XCTAssertEqual(result.runError, SessionCleanupCenter.quitRunError)
    }

    func testBackgroundApplyArguments() async throws {
        center.liveSessionIDs = { [4, 9] }
        let apply = Task { await center.applyInBackground(sessionID: 9, workbenchID: 2) }
        let run = try await XCTUnwrapAsync(await started())
        run.send(Self.cleanDone)
        run.finish()
        _ = await apply.value

        XCTAssertEqual(run.args, ["workbench", "cleanup", "--session=9", "--workbench=2", "--live-session=4",
                                  "--apply", "--json", "--stream"])
    }
}

/// `XCTUnwrap` over a value read with `await`.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// An environment read held until `open()`.
@MainActor
private final class EnvironmentGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async -> [String: String] {
        if !isOpen {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                let watching = watchers
                watchers = []
                watching.forEach { $0.resume() }
            }
        }
        return [:]
    }

    func untilWaiting() async {
        guard waiting.isEmpty else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}
