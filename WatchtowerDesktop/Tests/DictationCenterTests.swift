import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `stop()` failing to reach the CLI (behavior 5) uses this rather than a
/// generic error so a test failure message can't be confused with a real
/// `CLIRunnerError`.
private struct StubCleanupError: Error {}

/// A batch decode throwing (M3 fix-round regression) — kept distinct from
/// `StubCleanupError` so a test failure message can't be confused between
/// "the cleanup CLI failed" and "the transcriber itself failed".
private struct StubTranscribeError: Error {}

/// Canned `watchtower dictate clean --mode chat` stdout envelope.
private let chatCleanedEnvelope = Data(#"{"mode":"chat","text":"cleaned"}"#.utf8)

/// A `WhisperWindowEngine` that fails every window — `WindowedTranscriber`
/// (`transcribe()`) throws the last engine error when no window produced
/// speech, which is exactly the "batch decode itself failed" case M3 covers.
private final class ThrowingEngine: WhisperWindowEngine, @unchecked Sendable {
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 1.0] }
    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        throw StubTranscribeError()
    }
}

/// Suspends `wait()` callers until `release()` is called, then lets every
/// subsequent `wait()` (including ones that arrive after release) return
/// immediately — lets a test control exactly when an async fake (here,
/// `engineFactory`) resolves relative to other actions it wants to
/// interleave first (e.g. `cancel()`, `meetingCaptureWillStart()`).
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let toResume = waiters
        waiters = []
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}

@MainActor
final class DictationCenterTests: MeetingRecorderTestCase {

    // MARK: 1. Live happy path

    func testLiveHappyPathDeliversLiveTextThenCleanedResult() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello world"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var liveTexts: [String] = []
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { result = $0 })

        XCTAssertEqual(center.phase, .loadingEngine)
        await waitUntil("recording") { center.phase == .recording }

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(liveTexts.last, "hello world")
        XCTAssertEqual(center.lastRaw, "hello world")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
    }

    // MARK: 2. Batch fallback

    func testBatchFallbackWhenEngineHasNoLiveSession() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["batch text"]), supportsLive: false) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var liveTexts: [String] = []
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { result = $0 })

        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("result delivered") { result != nil }

        XCTAssertTrue(liveTexts.isEmpty, "a batch-only engine must never deliver live chunks")
        XCTAssertEqual(center.lastRaw, "batch text")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
    }

    /// M3 fix-round regression: a batch decode that throws must surface as a
    /// visible failure, not degrade into "nothing was said" — that would
    /// silently drop whatever the user actually dictated.
    func testBatchTranscribeErrorSurfacesAsFailedNotAnEmptyResult() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ThrowingEngine(), supportsLive: false) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var resultCalls = 0
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in resultCalls += 1 })

        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        XCTAssertEqual(center.phase, .failed("transcription failed"))
        XCTAssertEqual(resultCalls, 0, "a thrown batch decode must never present as a successful (empty) result")
        XCTAssertTrue(runner.invocations.isEmpty, "cleanup must never be reached when the transcript itself failed")
    }

    // MARK: 3. Dictation config

    func testConfigOverridesWindowAndDiarizationButLeavesBoundarySnapAndIgnoresLiveTranscriptionFlag() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        defaults.set(7.0, forKey: "transcription.boundarySnapSec")
        // Dictation liveness must come from `makeLiveSession` alone — proven
        // below by still getting live chunks despite this being false.
        defaults.set(false, forKey: "transcription.liveTranscription")

        var capturedConfig: TranscriptionConfig?
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { config in
                capturedConfig = config
                return TestTranscriber(ScriptedEngine(texts: ["hi there"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var liveTexts: [String] = []
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { result = $0 })

        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        let config = try XCTUnwrap(capturedConfig)
        XCTAssertEqual(config.windowSec, 10)
        XCTAssertFalse(config.diarization)
        XCTAssertEqual(config.boundarySnapSec, 7.0, "boundarySnapSec is untouched — whatever fromDefaults produced")
        XCTAssertFalse(liveTexts.isEmpty, "a false liveTranscription default must not force a batch fallback")
    }

    // MARK: 4. Degenerate stop

    func testDegenerateStopWithNoSamplesSkipsCleanupCall() async throws {
        let defaults = try isolatedDefaults()
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })

        await waitUntil("recording") { center.phase == .recording }
        center.stop() // no samples emitted at all

        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: ""))
        XCTAssertEqual(center.phase, .idle)
        XCTAssertTrue(runner.invocations.isEmpty, "an empty raw transcript must never reach the cleanup CLI")
    }

    // MARK: 5. Cleanup failure

    func testCleanupFailureKeepsRawTextAndNeverFiresOnResult() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: Data(), error: StubCleanupError())
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var resultCalls = 0
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in resultCalls += 1 })

        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        XCTAssertEqual(center.phase, .failed("cleanup failed — raw text kept"))
        XCTAssertEqual(resultCalls, 0)
        XCTAssertEqual(center.lastRaw, "said something")
        XCTAssertEqual(center.liveText, "said something")
    }

    // MARK: 6. Sticky engine

    /// A long TTL, so this is never at the mercy of how long the first
    /// dictation actually took (a CI stall here must not make the "still
    /// warm" assertion flaky) — the elapsed-TTL case is a separate test with
    /// its own short TTL.
    func testEngineIsReusedAcrossDictationsWithinTTL() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        func runOneDictation() async {
            var result: DictationCleanResult?
            center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
            await waitUntil("recording") { center.phase == .recording }
            lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
            center.stop()
            await waitUntil("result delivered") { result != nil }
        }

        await runOneDictation()
        XCTAssertEqual(engineLoads, 1)

        await runOneDictation()
        XCTAssertEqual(engineLoads, 1, "a second dictation within the TTL must reuse the warm engine")
    }

    func testEngineReloadsAfterIdleTTLElapses() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .milliseconds(5)
        )

        func runOneDictation() async {
            var result: DictationCleanResult?
            center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
            await waitUntil("recording") { center.phase == .recording }
            lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
            center.stop()
            await waitUntil("result delivered") { result != nil }
        }

        await runOneDictation()
        XCTAssertEqual(engineLoads, 1)

        try await Task.sleep(for: .milliseconds(50))
        await runOneDictation()
        XCTAssertEqual(engineLoads, 2, "once the idle TTL elapses the engine must be reloaded")
    }

    /// M1 fix-round regression: a dictation cancelled while its engine load
    /// is still in flight, raced against `meetingCaptureWillStart()` (which
    /// drops the — at that point still nil — warm engine and its release
    /// timer immediately, since the dictation is already idle), must never
    /// let the late-arriving load resurrect an uncached, un-timed resident
    /// engine once it finally resolves.
    func testCancelledEngineLoadNeverResurrectsAnUnmanagedWarmEngine() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        let gate = AsyncGate()
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                await gate.wait()
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        // `phase` flips to `.loadingEngine` synchronously inside `start()`,
        // before the dictation task is even scheduled — waiting on it would
        // let cancel()/meetingCaptureWillStart() below race ahead of the
        // engine factory ever being called at all. Wait for the factory call
        // itself so the race this test targets is the one actually created.
        await waitUntil("engine load started") { engineLoads >= 1 }
        XCTAssertEqual(engineLoads, 1)

        // Cancel the dictation, then race meetingCaptureWillStart() against
        // the still-in-flight engine load — both make their engine-slot
        // decision (armed/dropped a release timer) before the load resolves.
        center.cancel()
        center.meetingCaptureWillStart()

        gate.release() // let the stale, already-cancelled load resolve now
        for _ in 0..<5 { await Task.yield() }

        // A fresh dictation must reload — nothing should have re-cached the
        // just-resolved (but cancelled) engine with no release timer armed.
        var result: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(engineLoads, 2, "the cancelled load must never be cached without a release timer")
    }

    // MARK: 7. Meeting coordination

    func testMeetingCaptureWillStartDuringRecordingActsLikeStopAndDropsEngineAfterCleanup() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording") { center.phase == .recording }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))

        center.meetingCaptureWillStart()

        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"), "must deliver what was said, like stop()")
        XCTAssertEqual(lastRecorder.stopCalls, 1)
        XCTAssertEqual(engineLoads, 1)

        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { secondResult = $0 })
        await waitUntil("recording again") { center.phase == .recording }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second result delivered") { secondResult != nil }

        XCTAssertEqual(engineLoads, 2, "the engine must have been dropped once cleanup finished, forcing a reload")
    }

    func testMeetingCaptureWillStartWhileIdleDropsWarmEngineImmediately() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            // Long enough that only meetingCaptureWillStart (never elapsed
            // time) can explain the drop this test asserts on.
            engineIdleTTL: .seconds(900)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording") { center.phase == .recording }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(engineLoads, 1)

        center.meetingCaptureWillStart() // idle, warm engine present

        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { secondResult = $0 })
        await waitUntil("recording again") { center.phase == .recording }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second result delivered") { secondResult != nil }

        XCTAssertEqual(engineLoads, 2, "an idle warm engine must be dropped immediately, not left to the TTL")
    }

    func testStartIsANoOpWhileMeetingIsBusy() async throws {
        let defaults = try isolatedDefaults()
        let recorder = FakeMicRecorder()
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { FakeCLIRunner() },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        center.meetingBusy = { true }

        var callbackFired = false
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in callbackFired = true },
                     onResult: { _ in callbackFired = true })

        await Task.yield()

        XCTAssertEqual(center.phase, .idle)
        XCTAssertFalse(callbackFired)
        XCTAssertEqual(recorder.startCalls, 0)
    }

    // MARK: 8. Busy exclusivity

    func testStartWhileAnotherDictationIsActiveIsANoOp() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["first"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var firstResult: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { firstResult = $0 })
        await waitUntil("recording") { center.phase == .recording }

        var secondCallbackFired = false
        center.start(targetID: "t2", mode: .chat,
                     onLiveText: { _ in secondCallbackFired = true },
                     onResult: { _ in secondCallbackFired = true })

        XCTAssertEqual(center.activeTargetID, "t1", "the second start must not disturb the first dictation")
        XCTAssertFalse(secondCallbackFired)

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("first result delivered") { firstResult != nil }

        XCTAssertEqual(firstResult, DictationCleanResult(title: nil, text: "cleaned"))
    }

    // MARK: 9. Single onResult

    func testStopCalledTwiceFiresCleanupAndOnResultOnlyOnce() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var resultCalls = 0
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in resultCalls += 1 })
        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.stop()
        center.stop()

        await waitUntil("idle") { center.phase == .idle }
        await Task.yield()

        XCTAssertEqual(resultCalls, 1)
        XCTAssertEqual(runner.invocations.count, 1)
    }
}
