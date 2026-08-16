import Foundation
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
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

// `AsyncGate` and `GatedCLIRunner` live in
// `Tests/Helpers/DictationTestSupport.swift` — `DictationButtonViewTests`
// drives the same gated-center states.

@MainActor
final class DictationCenterTests: MeetingRecorderTestCase {

    /// Like `waitUntil`, but with wall-clock patience: the mid-stream live
    /// decode of a full window runs on the global executor across several
    /// actor hops, and 400 bare main-actor yields can burn through before
    /// the background chain ever gets scheduled.
    private func waitPatiently(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

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

        XCTAssertEqual(center.phase, .recording)
        XCTAssertTrue(center.isEngineLoading, "the mic is hot immediately; the engine load is a flag, not a phase")
        await waitUntil("engine loaded") { !center.isEngineLoading }

        // A full decidable window (windowSec 4 + its capped snap tolerance),
        // so the live chunk arrives while still `.recording` — a chunk
        // decoded only in the post-stop draining tail is deliberately
        // suppressed (the final text then arrives via the session's return
        // value alone).
        recorder.emit([Float](repeating: 0.1, count: 240_000))
        await waitPatiently("live text delivered") { !liveTexts.isEmpty }
        center.stop()

        // waitPatiently: the post-stop drain decodes several short windows on
        // the global executor before cleanup can even start.
        await waitPatiently("result delivered") { result != nil }

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

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
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

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        guard case .failed(let message) = center.phase else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.hasPrefix("transcription failed: "),
                      "the failure must carry the error detail, got: \(message)")
        XCTAssertEqual(resultCalls, 0, "a thrown batch decode must never present as a successful (empty) result")
        XCTAssertTrue(runner.invocations.isEmpty, "cleanup must never be reached when the transcript itself failed")
    }

    // MARK: 3. Dictation config

    func testConfigOverridesWindowSnapAndDiarizationAndIgnoresLiveTranscriptionFlag() async throws {
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

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        // A full decidable window, so the live chunk lands pre-stop (the
        // happy-path test documents why).
        recorder.emit([Float](repeating: 0.1, count: 240_000))
        await waitPatiently("live text delivered") { !liveTexts.isEmpty }
        center.stop()
        // waitPatiently: the post-stop drain decodes several short windows on
        // the global executor before cleanup can even start.
        await waitPatiently("result delivered") { result != nil }

        let config = try XCTUnwrap(capturedConfig)
        XCTAssertEqual(config.windowSec, 3)
        XCTAssertFalse(config.diarization)
        XCTAssertEqual(config.boundarySnapSec, 0,
                       "dictation disables boundary snapping (latency-first, owner call 2026-08-16) "
                       + "— the meeting Settings value must not leak in")
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

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
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
        var cleanupFailureRaw: String?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in },
                     onResult: { _ in resultCalls += 1 },
                     onCleanupFailure: { cleanupFailureRaw = $0 })

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        // A full decidable window, so the live chunk lands pre-stop (the
        // happy-path test documents why).
        recorder.emit([Float](repeating: 0.1, count: 240_000))
        await waitPatiently("live text delivered") { !center.liveText.isEmpty }
        center.stop()

        // waitPatiently: the post-stop drain decodes several short windows on
        // the global executor before the (failing) cleanup is even reached.
        await waitPatiently("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        XCTAssertEqual(center.phase, .failed("cleanup failed — raw text kept"))
        XCTAssertEqual(resultCalls, 0)
        XCTAssertEqual(center.lastRaw, "said something")
        XCTAssertEqual(center.liveText, "said something")
        XCTAssertEqual(cleanupFailureRaw, "said something",
                       "the raw transcript must be handed to the surface on cleanup failure")
    }

    /// M1 (final review): on a batch-only provider no live chunk ever reached
    /// the field, so `onCleanupFailure` is the ONLY delivery — composing it
    /// the way `DictationButton` does must leave the spoken words in the
    /// field, not an empty string.
    func testBatchOnlyCleanupFailureDeliversRawTextToTheField() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: Data(), error: StubCleanupError())
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["batch words"]), supportsLive: false) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var field = ""
        let base = DictationSpan.base(existing: field, mode: .chat)
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { field = DictationSpan.compose(base: base, dictated: $0) },
                     onResult: { field = DictationSpan.compose(base: base, dictated: $0.text) },
                     onCleanupFailure: { field = DictationSpan.compose(base: base, dictated: $0) })

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        XCTAssertEqual(field, "batch words", "cleanup failure must leave the raw transcript in the field")
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
            await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
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
            await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
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
        // A fresh recorder per start(), mirroring the production factory
        // (`{ MicRecorder() }`): t1's cancel() stops and permanently closes
        // its recorder's sample stream, so t2 must not inherit it — reusing
        // one instance across both starts would give t2 an already-finished
        // stream, and `capture()` would fall through empty before this test
        // ever gets to observe `.recording` as a held state.
        var currentRecorder: FakeMicRecorder!
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        let gate = AsyncGate()
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                currentRecorder = recorder
                return recorder
            },
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
        // `phase` flips to `.recording` (with `isEngineLoading`) synchronously
        // inside `start()`, before the dictation task is even scheduled —
        // waiting on it would let cancel()/meetingCaptureWillStart() below
        // race ahead of the engine factory ever being called at all. Wait for
        // the factory call itself so the race this test targets is the one
        // actually created.
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        currentRecorder.emit([Float](repeating: 0.1, count: 1_600))
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))

        center.meetingCaptureWillStart()

        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"), "must deliver what was said, like stop()")
        XCTAssertEqual(lastRecorder.stopCalls, 1)
        XCTAssertEqual(engineLoads, 1)

        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { secondResult = $0 })
        await waitUntil("engine loaded again") { center.phase == .recording && !center.isEngineLoading }
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(engineLoads, 1)

        center.meetingCaptureWillStart() // idle, warm engine present

        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { secondResult = $0 })
        await waitUntil("engine loaded again") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second result delivered") { secondResult != nil }

        XCTAssertEqual(engineLoads, 2, "an idle warm engine must be dropped immediately, not left to the TTL")
    }

    /// The meeting claiming the slot during the engine load now finalizes
    /// the dictation instead of cancelling it — speech buffered during a
    /// load is real and gets delivered — and still frees the slot: the
    /// engine is dropped (not parked) as soon as transcription completes,
    /// and `engineReleased` wakes the parked meeting live pass.
    func testMeetingCaptureWillStartDuringEngineLoadFinalizesAndFreesTheSlot() async throws {
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
                return TestTranscriber(ScriptedEngine(texts: ["spoken during load"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in },
                     onResult: { result = $0 })
        await waitUntil("engine load started") { engineLoads >= 1 }
        XCTAssertEqual(center.phase, .recording)
        XCTAssertTrue(center.isEngineLoading)
        XCTAssertTrue(center.hasResidentEngine, "an in-flight load counts as holding the slot")

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.meetingCaptureWillStart()

        XCTAssertEqual(center.phase, .stopping, "the meeting handshake finalizes, it no longer cancels")
        XCTAssertEqual(recorder.stopCalls, 1, "the mic must be turned off")

        gate.release() // the engine resolves now; the buffer is batch-decoded
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "speech spoken during the load must be delivered, not discarded")
        XCTAssertFalse(center.hasResidentEngine, "the engine must be dropped, not parked, once transcription completes")
        XCTAssertEqual(releaseFires, 1, "the parked meeting live pass must be woken")
        XCTAssertEqual(center.phase, .idle)
    }

    /// Judge-verify residual, reshaped for the finalize semantics: the
    /// meeting claiming the slot while a dictation is (re)starting inside
    /// the warm-engine reuse window must DROP the warm engine as the
    /// finalizing run completes, not leave it to the 15-min TTL — otherwise
    /// hasResidentEngine stays true and the meeting live pass parks with
    /// nothing left to ever fire engineReleased.
    func testMeetingCaptureWillStartDuringLoadWithWarmEngineDropsItImmediately() async throws {
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
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        // First dictation completes and leaves the engine warm.
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }
        XCTAssertTrue(center.hasResidentEngine)

        // Second dictation is synchronously recording (engine still resolving
        // out of the warm slot) right after start() — the reuse window, warm
        // engine still resident.
        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { secondResult = $0 })
        XCTAssertEqual(center.phase, .recording)
        XCTAssertTrue(center.isEngineLoading)

        center.meetingCaptureWillStart()

        // The handshake finalizes: nothing was said yet, so the run resolves
        // with an empty result — and drops the warm engine on its way out.
        await waitUntil("second (empty) result delivered") { secondResult != nil }

        XCTAssertFalse(center.hasResidentEngine,
                       "the warm engine must be dropped by the finalize, not left to the 15-min TTL")
        XCTAssertEqual(releaseFires, 1, "the parked meeting live pass must be woken")
        XCTAssertEqual(center.phase, .idle)

        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(engineLoads, 1, "the finalizing second dictation must reuse the warm engine, never load a new one")
        XCTAssertFalse(center.hasResidentEngine)
    }

    /// Final-review P2 (b): the meeting claiming the slot during cleanup must
    /// drop the (no longer needed) engine immediately — before the cleanup
    /// CLI call completes — while the cleanup itself still runs to completion
    /// and delivers the cleaned result.
    func testMeetingCaptureWillStartDuringCleaningDropsEngineButDeliversResult() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let gate = AsyncGate()
        let runner = GatedCLIRunner(gate: gate, stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("cleaning") { center.phase == .cleaning }
        XCTAssertTrue(center.hasResidentEngine, "the warm engine survives into the cleanup step")

        center.meetingCaptureWillStart()

        XCTAssertFalse(center.hasResidentEngine,
                       "the engine plays no part in cleanup — it must be dropped before cleanup completes")
        XCTAssertEqual(releaseFires, 1, "the parked meeting live pass is woken by engineReleased")

        gate.release() // the cleanup CLI call finishes now
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "the interrupted-at-cleaning dictation must still deliver its cleaned text")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertFalse(center.hasResidentEngine, "completion must not resurrect the dropped engine")
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }

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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.stop()
        center.stop()

        await waitUntil("idle") { center.phase == .idle }
        await Task.yield()

        XCTAssertEqual(resultCalls, 1)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    // MARK: 10. Host-view teardown (B1/B2, final review)

    /// The `DictationButton.onDisappear` path: an owned capture is cancelled
    /// when its host view unmounts — mic off, state reset — and the slot is
    /// immediately usable by another target.
    func testCancelOnHostViewDisappearFreesTheSlotForAnotherTarget() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        let firstRecorder = try XCTUnwrap(lastRecorder)

        // The onDisappear closure's exact logic: cancel only when owning.
        if center.activeTargetID == "t1" { center.cancel() }

        XCTAssertEqual(firstRecorder.stopCalls, 1, "cancel must turn the mic off")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.activeTargetID)

        var result: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("second target engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second target result") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
    }

    /// B2: a failure whose owning view is gone (nobody left to press retry)
    /// must not wedge dictation app-wide — a fresh start from ANY other
    /// target clears the orphaned `.failed` and proceeds.
    func testStartFromAnotherTargetUnwedgesAnOrphanedFailure() async throws {
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
                if engineLoads == 1 { throw StubTranscribeError() }
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }
        XCTAssertEqual(center.activeTargetID, "t1", "a failure keeps ownership so the owning button renders retry")

        var result: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("second target engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second target result") { result != nil }

        XCTAssertEqual(engineLoads, 2, "the un-wedged start must load a fresh engine")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 11. Mic capture errors (M3, final review)

    /// A latched mic conversion error with an empty capture must surface as a
    /// visible failure — never as a clean empty result that hides a broken
    /// capture path.
    func testEmptyCaptureWithLatchedMicErrorSurfacesAsFailed() async throws {
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

        recorder.lastError = StubCleanupError() // any latched capture error
        var resultCalls = 0
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in resultCalls += 1 })

        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        center.stop() // no samples ever arrived — but an error was latched

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        XCTAssertEqual(center.phase, .failed("microphone capture failed"))
        XCTAssertEqual(resultCalls, 0, "a broken capture must never present as a successful empty result")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// The mic failing to start at all (m8): `FakeMicRecorder.startError`
    /// must land in `.failed`, with no callbacks and no cleanup call.
    func testMicStartFailureSurfacesAsFailed() async throws {
        let defaults = try isolatedDefaults()
        let recorder = FakeMicRecorder()
        recorder.startError = MicRecorderError.engineStartFailed("boom")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var callbackFired = false
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in callbackFired = true },
                     onResult: { _ in callbackFired = true })

        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        guard case .failed(let message) = center.phase else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.hasPrefix("microphone failed to start"), "got: \(message)")
        XCTAssertFalse(callbackFired)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: 12. Stop / cancel during engine load

    /// A stop while the engine is still loading finalizes: the mic was hot
    /// and buffering the whole time, so the speech is batch-decoded once the
    /// engine resolves, cleaned, and delivered — never thrown away. Cancel
    /// (below) is the only discard path.
    func testStopDuringEngineLoadFinalizesAndDeliversText() async throws {
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
                return TestTranscriber(ScriptedEngine(texts: ["spoken during load"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in },
                     onResult: { result = $0 })
        await waitUntil("engine load started") { engineLoads >= 1 }
        XCTAssertEqual(center.phase, .recording)
        XCTAssertTrue(center.isEngineLoading)

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop() // during the load — must finalize, not cancel

        XCTAssertEqual(center.phase, .stopping, "stop during the load waits for the engine, it no longer cancels")

        gate.release() // the engine resolves now; the buffer is batch-decoded
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
    }

    /// Cancel is the only discard path — during the engine load it must
    /// still discard everything: mic off, idle, no callbacks, no decode of
    /// the buffered speech, no cleanup call (the old stop-during-load
    /// coverage under its true name).
    func testCancelDuringEngineLoadDiscardsEverything() async throws {
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
                return TestTranscriber(ScriptedEngine(texts: ["never delivered"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var callbackFired = false
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { _ in callbackFired = true },
                     onResult: { _ in callbackFired = true })
        await waitUntil("engine load started") { engineLoads >= 1 }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.cancel()

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.activeTargetID)
        XCTAssertEqual(recorder.stopCalls, 1, "the mic must be turned off")

        gate.release() // the stale load resolves after the fact
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(center.phase, .idle)
        XCTAssertFalse(callbackFired, "a cancelled dictation must never fire its callbacks")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: 13. Warm engine vs Settings changes (m3, final review)

    func testWarmEngineIsDroppedWhenModelSettingChangesBetweenDictations() async throws {
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
            await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
            lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
            center.stop()
            await waitUntil("result delivered") { result != nil }
        }

        await runOneDictation()
        XCTAssertEqual(engineLoads, 1)

        defaults.set("base", forKey: "dictation.model")
        await runOneDictation()
        XCTAssertEqual(engineLoads, 2, "a Settings change must drop the warm engine and reload")
    }

    /// Switching `dictation.model` to Apple must not strand a parked whisper
    /// engine: the apple lane skips `resolveTranscriber` (the only other
    /// invalidation site), so without an explicit drop `hasResidentEngine`
    /// would stay true forever and a meeting live pass would park on a dead
    /// reference with nothing left to ever fire `engineReleased`.
    func testSwitchingToAppleDropsParkedWhisperEngine() async throws {
        let defaults = try isolatedDefaults() // pins dictation.model = "small"
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
            sessionFactory: { choice, transcriber, config in
                if case .whisper = choice, let transcriber {
                    return WhisperDictationSession(transcriber: transcriber, config: config)
                }
                return FakeDictationSession(updates: ["hi"], finalText: "hi there")
            },
            appleSupported: { true },
            appleRuntimeSupportsLanguage: { _ in true },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        // A whisper dictation parks its engine warm.
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(engineLoads, 1)
        XCTAssertTrue(center.hasResidentEngine, "the whisper engine is parked warm after the dictation")
        XCTAssertEqual(releaseFires, 0)

        defaults.set("apple", forKey: "dictation.model")

        var liveTexts: [String] = []
        var secondResult: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { secondResult = $0 })
        await waitUntil("apple session delivering") { !liveTexts.isEmpty }

        XCTAssertFalse(center.hasResidentEngine,
                       "the apple run must drop the stale parked whisper engine, not carry it forever")
        XCTAssertEqual(releaseFires, 1, "the slot genuinely frees — a parked meeting live pass must be woken")

        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second result delivered") { secondResult != nil }

        XCTAssertEqual(secondResult, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(engineLoads, 1, "the apple lane must never load a whisper engine")
        XCTAssertFalse(center.hasResidentEngine)
        XCTAssertEqual(center.phase, .idle)
    }

    /// The 2026-08-16 live-repro: `dictation.model` resolves to the apple
    /// lane, but this machine's `SpeechTranscriber` runtime ships no model
    /// for the dictation language (the catalog said ru is fine; the runtime
    /// disagreed and BOTH the streaming session and the batch fallback died
    /// with no text). The run must degrade to the whisper lane and deliver.
    func testAppleLaneDegradesToWhisperWhenRuntimeLacksTheLanguage() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("apple", forKey: "dictation.model")
        defaults.set("ru", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var checkedLocales: [Locale] = []
        var sessionChoices: [DictationEngineChoice] = []
        var lastRecorder: FakeMicRecorder!
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            engineFactory: { config in
                XCTAssertEqual(config.model, "small", "the degrade must load the fallback whisper model")
                return TestTranscriber(ScriptedEngine(texts: ["сказал что-то"]), supportsLive: true)
            },
            sessionFactory: { choice, transcriber, config in
                sessionChoices.append(choice)
                if case .whisper = choice, let transcriber {
                    return WhisperDictationSession(transcriber: transcriber, config: config)
                }
                return FakeDictationSession(updates: ["never"], finalText: "never")
            },
            appleSupported: { true },
            appleRuntimeSupportsLanguage: { locale in
                checkedLocales.append(locale)
                return false
            },
            runnerResolver: { runner },
            defaults: defaults
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(checkedLocales.map(\.identifier), ["ru-RU"],
                       "the gate checks the app's resolved dictation locale")
        XCTAssertEqual(sessionChoices, [.whisper(model: "small")],
                       "an unsupported runtime language never builds the apple session")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
    }

    // MARK: 14. Pause / resume, elapsed time, mic level

    /// Pause gates samples out of the session (the mic stays hot, the
    /// recorder simply drops chunks); resume continues the SAME session — one
    /// stop at the end delivers everything said across the pause.
    func testPauseGatesSamplesAndResumeContinuesSameSession() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["part one part two"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        // The feed loop consumes chunks asynchronously — wait for this one to
        // land so pause()'s micLevel reset can't be overwritten by it.
        await waitUntil("chunk fed") { center.micLevel > 0 }
        center.pause()
        XCTAssertEqual(center.phase, .paused)
        XCTAssertEqual(recorder.pausedStates, [true])
        XCTAssertEqual(center.micLevel, 0, "pause must zero the level meter")

        recorder.emit([Float](repeating: 0.9, count: 1_600)) // dropped by the fake's gate

        center.resume()
        XCTAssertEqual(center.phase, .recording)
        XCTAssertEqual(recorder.pausedStates, [true, false])

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

    /// Stop from `.paused` finalizes exactly like from `.recording` — pause
    /// never becomes a trap the user can only cancel out of.
    func testStopFromPausedFinalizes() async throws {
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

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.pause()
        XCTAssertEqual(center.phase, .paused)
        center.stop()

        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
    }

    /// Paused time never ticks: pause folds the open span into
    /// `elapsedAccumulated` and nils `spanStartedAt`, so `elapsed(now:)` is
    /// frozen no matter how far the (monotonic) clock advances.
    func testElapsedDoesNotTickWhilePaused() async throws {
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

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("recording") { center.phase == .recording }

        center.pause()

        XCTAssertNil(center.spanStartedAt)
        let t0 = ContinuousClock.now
        let frozen = center.elapsed(now: t0)
        XCTAssertEqual(center.elapsed(now: t0 + .seconds(10)), frozen,
                       "elapsedAccumulated must be frozen while paused")

        center.cancel()
    }

    /// `micLevel` is the RMS of the latest chunk while recording, and reads 0
    /// once the dictation is back to idle.
    func testMicLevelTracksChunkRMSAndResetsOnIdle() async throws {
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

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        recorder.emit([Float](repeating: 0.2, count: 8_000))
        await waitUntil("mic level updated") { center.micLevel > 0 }
        XCTAssertEqual(center.micLevel, 0.2, accuracy: 0.01, "RMS of a constant 0.2 chunk is 0.2")

        center.stop()
        // waitPatiently: the decode + cleanup chain hops executors, and bare
        // main-actor yields can burn out before it gets scheduled under load.
        await waitPatiently("result delivered") { result != nil }

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(center.micLevel, 0, "idle must zero the level meter")
    }

    /// The meeting claiming the slot while the dictation is paused takes the
    /// finalize path: deliver what was said, drop the engine (not parked),
    /// wake the parked meeting live pass.
    func testMeetingCaptureWillStartFromPausedFinalizes() async throws {
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
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.pause()
        XCTAssertEqual(center.phase, .paused)

        center.meetingCaptureWillStart()

        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "speech said before the pause must be delivered, not discarded")
        XCTAssertFalse(center.hasResidentEngine, "the engine must be dropped, not parked")
        XCTAssertEqual(releaseFires, 1, "the parked meeting live pass must be woken")
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 15. Safety automations (silence auto-pause, pause-timeout auto-stop)

    /// Silence tracking is sample-clock based: N samples of sub-threshold RMS
    /// accumulate `N / 16_000` seconds of silence, so the test emits audio
    /// instead of sleeping. Crossing the injected 1 s threshold auto-pauses.
    func testSilenceAutoPausesAfterThreshold() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            silenceAutoPauseAfter: .seconds(1),
            silenceRMSThreshold: 0.01
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        // 0.5 s of loud audio — well under the 1 s silence threshold.
        recorder.emit([Float](repeating: 0.2, count: 8_000))
        await waitUntil("loud chunk fed") { center.micLevel > 0 }
        XCTAssertEqual(center.phase, .recording, "loud audio must never trigger the silence auto-pause")

        // 1.5 s of silence (zeros) crosses the 1 s threshold mid-stream.
        recorder.emit([Float](repeating: 0, count: 8_000))
        recorder.emit([Float](repeating: 0, count: 8_000))
        recorder.emit([Float](repeating: 0, count: 8_000))
        await waitUntil("auto-paused") { center.phase == .paused }

        XCTAssertEqual(recorder.pausedStates, [true], "the auto-pause must gate the recorder like a manual pause")

        center.cancel()
    }

    /// A loud chunk resets the silence counter — only CONSECUTIVE silence
    /// auto-pauses, so 0.8 s + 0.8 s split by speech never adds up to 1 s.
    func testLoudChunkResetsSilenceCounter() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            silenceAutoPauseAfter: .seconds(1),
            silenceRMSThreshold: 0.01
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        recorder.emit([Float](repeating: 0, count: 12_800)) // 0.8 s silence
        recorder.emit([Float](repeating: 0.2, count: 1_600)) // speech — resets the counter
        // The feed loop consumes in order: once the loud chunk's level lands,
        // the preceding silence has been accounted too.
        await waitUntil("loud chunk fed") { center.micLevel > 0 }

        recorder.emit([Float](repeating: 0, count: 12_800)) // 0.8 s silence again
        await waitUntil("second silence fed") { center.micLevel == 0 }

        XCTAssertEqual(center.phase, .recording,
                       "0.8 s + 0.8 s of silence split by speech must never add up to an auto-pause")

        center.cancel()
    }

    /// A dictation left `.paused` past the timeout performs a NORMAL stop:
    /// finalize + clean + deliver — nothing is lost, nothing keeps holding
    /// the mic or the engine.
    func testPauseTimeoutAutoStopsAndDelivers() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            pauseAutoStopAfter: .milliseconds(50)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.pause()
        XCTAssertEqual(center.phase, .paused)

        // waitPatiently, not waitUntil: bare yields burn no wall-clock, and
        // the 50 ms timeout must actually elapse before the auto-stop fires.
        await waitPatiently("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "the auto-stop must finalize and deliver, exactly like a manual stop")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
    }

    /// Resuming before the timeout fires cancels it — the session keeps
    /// recording, nothing is delivered behind the user's back.
    func testResumeCancelsPauseTimeout() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            pauseAutoStopAfter: .milliseconds(50)
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        center.pause()
        center.resume()

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(center.phase, .recording, "resume must cancel the pause-timeout auto-stop")
        XCTAssertNil(result, "nothing may be delivered while the resumed session is still recording")

        center.cancel()
    }

    // MARK: 16. Stop racing mic startup (hot-mic blocker)

    /// A stop that lands while the mic is still starting up (the real
    /// recorder suspends in the permission request) must never leave the
    /// just-started engine hot with nothing left to stop it: the recorder
    /// latches the stop and backs out of its startup, and the center
    /// belt-and-braces re-stops once `start()` has completed. The fake's
    /// ordering log is the assertable proxy — "stop-after-start" proves a
    /// REAL stop happened on a completed start.
    func testStopWhileMicIsStartingNeverLeavesTheMicHot() async throws {
        let defaults = try isolatedDefaults()
        let recorder = FakeMicRecorder()
        let gate = AsyncGate()
        recorder.onStart = { await gate.wait() }
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
        await waitUntil("mic start began") { recorder.events.contains("start-begin") }

        center.stop() // lands while the mic startup is still suspended
        XCTAssertEqual(center.phase, .stopping)
        XCTAssertEqual(recorder.events, ["start-begin", "stop"])

        gate.release() // the mic startup completes now

        await waitUntil("resolved") { result != nil }
        XCTAssertEqual(center.phase, .idle, "the run must reach a terminal state, not hang")
        XCTAssertGreaterThanOrEqual(recorder.stopCalls, 2,
                                    "the completed start must be answered with a second, real stop")
        XCTAssertEqual(recorder.events, ["start-begin", "stop", "start-end", "stop-after-start"],
                       "the belt-and-braces re-stop must land AFTER start completed — the mic is never left hot")
    }

    // MARK: 17. Pause during engine load (live-session blocker)

    /// A pause during the engine load must not permanently kill live
    /// transcription: the mic is still open (`.paused` gates samples, it
    /// does not stop), so once the engine resolves and the user resumes,
    /// live chunks must flow.
    func testPauseDuringEngineLoadStillDeliversLiveTextAfterResume() async throws {
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
                return TestTranscriber(ScriptedEngine(texts: ["hello world"]), supportsLive: true)
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
        await waitUntil("engine load started") { engineLoads >= 1 }

        center.pause() // during the load
        XCTAssertEqual(center.phase, .paused)

        gate.release()
        await waitUntil("engine loaded") { !center.isEngineLoading }

        center.resume()
        XCTAssertEqual(center.phase, .recording)

        // A full decodable window (windowSec 4 + its capped snap tolerance)
        // so the live chunk lands while still `.recording` (the happy-path
        // test documents why).
        recorder.emit([Float](repeating: 0.1, count: 240_000))
        await waitPatiently("live text delivered") { !liveTexts.isEmpty }
        center.stop()
        // waitPatiently: the post-stop drain decodes several short windows on
        // the global executor before cleanup can even start.
        await waitPatiently("result delivered") { result != nil }

        XCTAssertEqual(liveTexts.last, "hello world",
                       "a pause during the engine load must not permanently kill live transcription")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 18. Stale pause timeout

    /// An engine-load failure landing while `.paused` must disarm the pause
    /// timeout — a stale 50 ms timer must never fire a stop() into the NEXT
    /// dictation.
    func testEngineLoadFailureWhilePausedDisarmsPauseTimeout() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        var engineLoads = 0
        let gate = AsyncGate()
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                if engineLoads == 1 {
                    await gate.wait()
                    throw StubTranscribeError()
                }
                return TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            pauseAutoStopAfter: .milliseconds(50)
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("engine load started") { engineLoads >= 1 }
        center.pause() // arms the 50 ms pause timeout
        XCTAssertEqual(center.phase, .paused)

        gate.release() // the load throws now → `.failed` while paused
        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        // A fresh dictation from another target (the orphaned-failure
        // unwedge path). A stale pause timer, were it still armed, would
        // fire ~50 ms in and stop this brand-new session behind the
        // user's back.
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("second dictation recording") { center.phase == .recording && !center.isEngineLoading }

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(center.phase, .recording,
                       "a stale pause timeout from the failed session must never stop the new one")

        center.cancel()
    }

    // MARK: 19. Cancel during stopping/cleaning

    /// The user walking away mid-cleanup: cancel returns to idle and the
    /// gated CLI call resolving after the fact must not resurrect any state,
    /// fire a late onResult, or block a fresh start for another target.
    func testCancelDuringStoppingDoesNotResurrectState() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        var lastRecorder: FakeMicRecorder!
        let gate = AsyncGate()
        let runner = GatedCLIRunner(gate: gate, stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: {
                let recorder = FakeMicRecorder()
                lastRecorder = recorder
                return recorder
            },
            // Two scripted windows: the cancelled first dictation consumes
            // one, the fresh second dictation (same warm engine) the other.
            engineFactory: { _ in
                TestTranscriber(ScriptedEngine(texts: ["said something", "said something"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var resultCalls = 0
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in resultCalls += 1 })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("cleaning") { center.phase == .cleaning }

        center.cancel()
        XCTAssertEqual(center.phase, .idle)

        gate.release() // the gated CLI call resolves after the fact
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(center.phase, .idle, "a late-resolving cleanup must never resurrect state after cancel")
        XCTAssertEqual(resultCalls, 0, "no onResult may fire after cancel")
        XCTAssertNil(center.activeTargetID)

        // The slot is immediately usable by another target.
        var result: DictationCleanResult?
        center.start(targetID: "t2", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("second engine loaded") { center.phase == .recording && !center.isEngineLoading }
        lastRecorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("second result") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
    }

    // MARK: 20. Draining silent tail after stop

    /// Silent chunks draining through the feed loop AFTER a stop (phase
    /// `.stopping`) must never re-trigger the silence auto-pause — the
    /// resolution completes normally.
    func testDrainingSilentTailAfterStopNeverRePauses() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            silenceAutoPauseAfter: .seconds(1),
            silenceRMSThreshold: 0.01
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        // Speech, then ~0.9 s of silence accumulated while still recording.
        recorder.emit([Float](repeating: 0.2, count: 1_600))
        await waitUntil("speech chunk fed") { center.micLevel > 0 }
        recorder.emit([Float](repeating: 0, count: 14_400)) // 0.9 s
        await waitUntil("silence fed") { center.micLevel == 0 }

        // More silence emitted back-to-back with the stop: those chunks
        // drain through the feed loop while the phase is already
        // `.stopping`, and together with the 0.9 s they'd cross the 1 s
        // threshold were they (wrongly) still counted.
        recorder.emit([Float](repeating: 0, count: 8_000))
        recorder.emit([Float](repeating: 0, count: 8_000))
        center.stop()

        await waitUntil("result delivered") { result != nil }

        XCTAssertTrue(recorder.pausedStates.isEmpty,
                      "the draining silent tail after a stop must never re-pause")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 21. Meeting handshake while already stopping

    /// The meeting claiming the slot while a manual stop is already
    /// finalizing (`.stopping` held open by a gated engine load): a single
    /// delivery, a single recorder stop, the engine dropped for the meeting
    /// and `engineReleased` fired.
    func testSecondMeetingCaptureWillStartWhileAlreadyStoppingIsANoOp() async throws {
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
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        var resultCalls = 0
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in },
                     onResult: { result = $0; resultCalls += 1 })
        await waitUntil("engine load started") { engineLoads >= 1 }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.stop() // manual stop first — the run is already finalizing
        XCTAssertEqual(center.phase, .stopping)

        center.meetingCaptureWillStart() // second claim, while already stopping

        XCTAssertEqual(center.phase, .stopping, "the handshake must not disturb the in-flight finalize")
        XCTAssertEqual(recorder.stopCalls, 1, "the handshake's stop() is a guarded no-op while already stopping")

        gate.release()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(resultCalls, 1, "exactly one delivery")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertFalse(center.hasResidentEngine, "the engine must be dropped for the meeting")
        XCTAssertEqual(releaseFires, 1, "engineReleased must fire (once) to wake the parked live pass")
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 22. Silence auto-pause → pause timeout, end to end

    /// The two safety automations chained: silence auto-pauses, the untouched
    /// pause times out, and the auto-stop finalizes and delivers — the
    /// abandoned-session path never loses what was said.
    func testSilenceAutoPauseThenPauseTimeoutDeliversEndToEnd() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900),
            silenceAutoPauseAfter: .seconds(1),
            pauseAutoStopAfter: .milliseconds(50),
            silenceRMSThreshold: 0.01
        )

        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("recording, engine loaded") { center.phase == .recording && !center.isEngineLoading }

        recorder.emit([Float](repeating: 0.2, count: 8_000)) // 0.5 s of speech
        // 1.5 s of silence crosses the 1 s threshold → auto-pause.
        recorder.emit([Float](repeating: 0, count: 8_000))
        recorder.emit([Float](repeating: 0, count: 8_000))
        recorder.emit([Float](repeating: 0, count: 8_000))
        await waitUntil("auto-paused") { center.phase == .paused }

        // Do nothing: the pause timeout must auto-stop and deliver.
        await waitPatiently("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "silence auto-pause chained into the pause timeout must still deliver")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
    }
}
