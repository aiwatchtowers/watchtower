import Foundation
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// A thrown apple session / whisper engine-load failure in this file — kept
/// distinct from `DictationCenterTests`'s `StubCleanupError` so a test
/// failure message can't be confused between "the cleanup CLI failed" and
/// "the transcriber/session itself failed". Named apart from
/// `DictationCenterRealtimeTests`'s identical private helper too — sentrux's
/// symbol resolver doesn't respect Swift's `private` file scoping, so two
/// same-named private declarations in sibling files register as a spurious
/// cross-file edge and trip the god-file gate.
private struct AppleLaneStubTranscribeError: Error {}

/// Canned `watchtower dictate clean --mode chat` stdout envelope.
private let chatCleanedEnvelope = Data(#"{"mode":"chat","text":"cleaned"}"#.utf8)

/// Split from `DictationCenterTests` (file_length): the live-text-replacement
/// half of MARK 23 plus the Apple lane (MARK 24) of the original suite — kept
/// apart from `DictationCenterRealtimeTests` because together they push that
/// file's fan-out over sentrux's god-file threshold.
@MainActor
final class DictationCenterAppleLaneTests: MeetingRecorderTestCase {

    /// A session update REPLACES the live text wholesale (volatile refinement
    /// lands in the field), the session's returned string is the raw
    /// transcript, and cleanup runs on that return.
    func testLiveTextIsFullReplacementNotAppend() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = TranscriptCapturingRunner(stdout: chatCleanedEnvelope)
        let session = FakeDictationSession(updates: ["hello", "hello world corrected"],
                                           finalText: "hello world corrected")
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            sessionFactory: { _, _, _ in session },
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
        await waitUntil("both updates delivered") { liveTexts.count == 2 }

        XCTAssertEqual(liveTexts, ["hello", "hello world corrected"],
                       "a refined update must REPLACE the live text wholesale, never append")
        XCTAssertEqual(center.liveText, "hello world corrected")

        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(center.lastRaw, "hello world corrected",
                       "the session's returned string is the raw transcript")
        XCTAssertEqual(runner.savedTranscripts, ["hello world corrected"],
                       "cleanup must run on the session's final return")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: 24. Apple lane (realtime dictation, Task 3)

    /// The apple lane never touches the whisper engine machinery: no
    /// engineFactory call, no warm slot — `hasResidentEngine` stays false the
    /// whole dictation, so the meeting recorder never waits on it.
    func testAppleLaneNeverHoldsTheEngineSlot() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("apple", forKey: "dictation.model")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let session = FakeDictationSession(updates: ["hi"], finalText: "hi there")
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                XCTFail("the apple lane must never load a whisper engine")
                throw AppleLaneStubTranscribeError()
            },
            sessionFactory: { _, _, _ in session },
            appleSupported: { true },
            appleRuntimeSupportsLanguage: { _ in true },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var liveTexts: [String] = []
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { result = $0 })

        await waitUntil("session delivering") { !liveTexts.isEmpty }
        XCTAssertEqual(center.phase, .recording)
        XCTAssertFalse(center.hasResidentEngine,
                       "an apple dictation with no parked whisper engine must never hold the slot")
        XCTAssertFalse(center.isEngineLoading,
                       "the badge covers only the run-up to the session owning the stream")

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.lastRaw, "hi there", "the session's returned string is the raw transcript")
        XCTAssertFalse(center.hasResidentEngine)
    }

    /// The meeting handshake mid-apple-dictation: finalize + deliver like
    /// stop(), and the slot is free — `engineReleased` still fires so a
    /// parked meeting live pass re-checks (a guarded no-op wake, since
    /// nothing was ever resident).
    func testMeetingHandshakeDuringAppleDictationFinalizesAndFreesSlot() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("apple", forKey: "dictation.model")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: chatCleanedEnvelope)
        let session = FakeDictationSession(updates: ["hi"], finalText: "hi there")
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                XCTFail("the apple lane must never load a whisper engine")
                throw AppleLaneStubTranscribeError()
            },
            sessionFactory: { _, _, _ in session },
            appleSupported: { true },
            appleRuntimeSupportsLanguage: { _ in true },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var releaseFires = 0
        center.engineReleased = { releaseFires += 1 }

        var liveTexts: [String] = []
        var result: DictationCleanResult?
        center.start(targetID: "t1", mode: .chat,
                     onLiveText: { liveTexts.append($0) },
                     onResult: { result = $0 })
        await waitUntil("session delivering") { !liveTexts.isEmpty }
        recorder.emit([Float](repeating: 0.1, count: 1_600))

        center.meetingCaptureWillStart()

        await waitUntil("result delivered") { result != nil }
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"),
                       "the handshake finalizes and delivers, like stop()")
        XCTAssertFalse(center.hasResidentEngine)
        XCTAssertEqual(releaseFires, 1, "the parked meeting live pass must be woken")
        XCTAssertEqual(center.phase, .idle)
    }

    /// A thrown apple session must not lose the speech: the t0 buffer is
    /// batch-decoded through the apple-lane fallback (a fresh batch
    /// transcriber over the buffered audio), and the decode's text flows
    /// into cleanup exactly like a session return.
    func testAppleSessionFailureFallsBackToBufferDecode() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("apple", forKey: "dictation.model")
        let recorder = FakeMicRecorder()
        let runner = TranscriptCapturingRunner(stdout: chatCleanedEnvelope)
        let session = FakeDictationSession(updates: ["hi"], finalText: "never returned",
                                           errorAfterDrain: AppleLaneStubTranscribeError())
        var decodedBuffers: [[Float]] = []
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                XCTFail("the apple lane must never load a whisper engine")
                throw AppleLaneStubTranscribeError()
            },
            sessionFactory: { _, _, _ in session },
            appleSupported: { true },
            appleRuntimeSupportsLanguage: { _ in true },
            appleBatchFallback: { samples, _ in
                decodedBuffers.append(samples)
                return "buffer decoded"
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
        await waitUntil("session delivering") { !liveTexts.isEmpty }

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        // The feed loop consumes chunks asynchronously — make sure this one
        // reached the t0 buffer before the stop, so the fallback has audio.
        await waitUntil("chunk buffered") { center.micLevel > 0 }
        center.stop()

        await waitUntil("result delivered") { result != nil }

        XCTAssertEqual(decodedBuffers.count, 1, "the thrown session must trigger exactly one buffer decode")
        XCTAssertEqual(decodedBuffers.first?.count, 1_600, "the decode must cover the t0 buffer")
        XCTAssertEqual(center.lastRaw, "buffer decoded")
        XCTAssertEqual(runner.savedTranscripts, ["buffer decoded"],
                       "cleanup must run on the fallback decode's text")
        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "cleaned"))
        XCTAssertEqual(center.phase, .idle)
    }

}
