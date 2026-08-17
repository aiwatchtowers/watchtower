import Foundation
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// A thrown apple session / whisper engine-load failure in this file — kept
/// distinct from `DictationCenterTests`'s `StubCleanupError` so a test
/// failure message can't be confused between "the cleanup CLI failed" and
/// "the transcriber/session itself failed".
private struct StubTranscribeError: Error {}

/// Canned `watchtower dictate clean --mode chat` stdout envelope.
private let chatCleanedEnvelope = Data(#"{"mode":"chat","text":"cleaned"}"#.utf8)

/// Split from `DictationCenterTests` (file_length): the dictation-model
/// seam and the Feature Manager ML-residency toggle — the config-only half
/// of MARK 23 plus MARK 25 of the original suite. The live-text-replacement
/// half of MARK 23 and the Apple lane (MARK 24) live in
/// `DictationCenterAppleLaneTests` (kept apart because together they push
/// this file's fan-out over sentrux's god-file threshold).
@MainActor
final class DictationCenterRealtimeTests: MeetingRecorderTestCase {

    // MARK: 23. Dictation model + session seam (realtime dictation, Task 2)

    func testDictationConfigUsesFourSecondWindowsAndDictationModel() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        // The meeting model key must be IGNORED — proven by config.model
        // below still being the dictation choice.
        defaults.set("large-v3-v20240930", forKey: "transcription.model")

        var capturedConfig: TranscriptionConfig?
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { config in
                capturedConfig = config
                return TestTranscriber(ScriptedEngine(texts: ["hi"]), supportsLive: true)
            },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }

        let config = try XCTUnwrap(capturedConfig)
        XCTAssertEqual(config.windowSec, 3, "dictation decodes ~3 s windows, not the meeting default")
        XCTAssertEqual(config.model, "small",
                       "the whisper model must come from dictation.model, never transcription.model")
        XCTAssertFalse(config.diarization)

        center.cancel()
    }

    // MARK: 25. ML engines residency toggle (Feature Manager, ml.keepEnginesWarm)

    /// `ml.keepEnginesWarm=false` (the Settings → Features "Keep ML engines in
    /// memory" row): a finished dictation must drop its engine right away
    /// instead of parking it for `engineIdleTTL` — the
    /// `testMeetingCaptureWillStartWhileIdleDropsWarmEngineImmediately` shape,
    /// triggered by the toggle instead of the meeting handshake. A long TTL
    /// proves only the toggle (never elapsed time) explains the drop.
    func testKeepEnginesWarmOffDropsEngineImmediatelyAfterDictation() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        defaults.set(false, forKey: DictationCenter.keepEnginesWarmKey)
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertFalse(center.hasResidentEngine,
                       "keepEnginesWarm=false must drop the engine right after delivery, not park it")
        XCTAssertEqual(releaseFires, 1, "the drop must wake a parked meeting live pass like any other release")
    }

    /// The default (key absent) must still be ON — every other sticky-engine
    /// test in this suite relies on that and never sets the key.
    func testKeepEnginesWarmAbsentDefaultsToOnAndKeepsEngineWarm() async throws {
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
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertTrue(center.hasResidentEngine, "absent ml.keepEnginesWarm must default to ON, parking the engine")
    }
}
