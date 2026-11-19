import Foundation
import XCTest
@testable import WatchtowerCore

/// A `watchtower` stand-in for Settings' pause: records argv, can fail, and
/// can hold a call until released.
private final class PauseRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var stderr: String?
    private var holds = false
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isStarted = false

    var calls: [[String]] { lock.withLock { recorded } }

    init(stderr: String? = nil, holds: Bool = false) {
        self.stderr = stderr
        self.holds = holds
    }

    func run(args: [String]) async throws -> Data {
        let (hold, waiter) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            recorded.append(args)
            isStarted = true
            defer { started = nil }
            return (holds, started)
        }
        waiter?.resume()
        if hold {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        }
        if let stderr = lock.withLock({ stderr }) { throw CLIRunnerError.nonZeroExit(code: 1, stderr: stderr) }
        return Data()
    }

    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if isStarted { return true }
                started = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Lets a held call return. Spins the main actor until the call is
    /// parked (no clock): the gate is set right after the start signal.
    @MainActor
    func release() async {
        while lock.withLock({ gate == nil }) { await Task.yield() }
        lock.withLock {
            gate?.resume()
            gate = nil
        }
    }
}

@MainActor
final class BackgroundAISettingsModelTests: XCTestCase {
    private func consent(_ runner: PauseRunner) -> BackgroundAIConsentModel {
        BackgroundAIConsentModel(
            runner: runner, configPath: "/tmp/acme/config.yaml",
            agent: .claude, reserve: nil, pollMinutes: 15, backfillDays: 30
        )
    }

    /// config.yaml cannot be read, so no model: the switch's turn-off
    /// re-reads the file (which then shows the config error) and calls no CLI.
    func testNilModelReloadsWithoutCLI() async {
        let settings = BackgroundAISettingsModel()
        var reloads = 0
        await settings.pause(make: { nil }, reload: { reloads += 1 })
        XCTAssertEqual(reloads, 1)
        XCTAssertNil(settings.consent)
        XCTAssertNil(settings.errorLine)
        XCTAssertFalse(settings.isSaving)
    }

    func testSavedPauseReloadsAndClears() async {
        let runner = PauseRunner()
        let settings = BackgroundAISettingsModel()
        var reloads = 0
        await settings.pause(make: { self.consent(runner) }, reload: { reloads += 1 })
        XCTAssertEqual(runner.calls, [["--config", "/tmp/acme/config.yaml", "ai", "background", "pause"]])
        XCTAssertEqual(reloads, 1)
        XCTAssertNil(settings.consent)
    }

    /// A failed pause keeps its line (background AI is still on) until the
    /// stored answer changes; nothing else clears it.
    func testFailedPauseKeepsErrorUntilStoredChange() async {
        let runner = PauseRunner(stderr: "Error: disk full")
        let settings = BackgroundAISettingsModel()
        var reloads = 0
        await settings.pause(make: { self.consent(runner) }, reload: { reloads += 1 })
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(settings.errorLine, BackgroundAIConsentCopy.pauseFailed("disk full"))
        settings.storedStateChanged()
        XCTAssertNil(settings.errorLine)
    }

    /// The stored answer changed while the pause was in flight (answered in
    /// the sheet): the spinner stays until the call returns, then its stale
    /// failure is dropped.
    func testStoredChangeWhileBusyDropsTheOutcome() async {
        let runner = PauseRunner(stderr: "Error: disk full", holds: true)
        let settings = BackgroundAISettingsModel()
        let pause = Task { await settings.pause(make: { self.consent(runner) }, reload: {}) }
        await runner.waitForStart()
        XCTAssertTrue(settings.isSaving)
        settings.storedStateChanged()
        XCTAssertTrue(settings.isSaving, "a pause in flight keeps its spinner")
        await runner.release()
        await pause.value
        XCTAssertNil(settings.errorLine)
        XCTAssertFalse(settings.isSaving)
    }

    /// A second turn-off while one is saving writes nothing more.
    func testPauseWhileBusyIsIgnored() async {
        let runner = PauseRunner(holds: true)
        let settings = BackgroundAISettingsModel()
        let first = Task { await settings.pause(make: { self.consent(runner) }, reload: {}) }
        await runner.waitForStart()
        var made = 0
        await settings.pause(make: { made += 1; return nil }, reload: {})
        XCTAssertEqual(made, 0)
        await runner.release()
        await first.value
        XCTAssertEqual(runner.calls.count, 1)
    }
}
