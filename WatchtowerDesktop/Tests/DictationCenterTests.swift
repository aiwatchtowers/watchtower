import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `stop()` failing to reach the CLI (behavior 5) uses this rather than a
/// generic error so a test failure message can't be confused with a real
/// `CLIRunnerError`.
private struct StubCleanupError: Error {}

/// Canned `watchtower dictate clean --mode chat` stdout envelope.
private let chatCleanedEnvelope = Data(#"{"mode":"chat","text":"cleaned"}"#.utf8)

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

    func testEngineStaysWarmWithinTTLAndReloadsAfterItElapses() async throws {
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

        await runOneDictation()
        XCTAssertEqual(engineLoads, 1, "a second dictation within the TTL must reuse the warm engine")

        try await Task.sleep(for: .milliseconds(50))
        await runOneDictation()
        XCTAssertEqual(engineLoads, 2, "once the idle TTL elapses the engine must be reloaded")
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
