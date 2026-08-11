import Foundation
import XCTest
@testable import WatchtowerDesktop

/// The warm engine slot on `MeetingRecorderCenter`: parking after a job,
/// reuse by the next recording, the warm-policy poll (unload / hold /
/// prewarm), key invalidation, and prewarm failure. Split from
/// `MeetingRecorderQueueTests` (fixtures in `MeetingRecorderTestCase`) to
/// keep the files within the lint budget. Pure decision-matrix coverage
/// lives in `WarmEnginePolicyTests`; these tests drive the Center's side
/// effects — always with an injected `engineKey`/clock/meetings provider,
/// never a real Settings read or wall-clock wait.
@MainActor
final class MeetingRecorderWarmEngineTests: MeetingRecorderTestCase {

    /// Fixed reference instant handed to the Center as its clock; meeting
    /// windows are built as offsets from it (no absolute dates).
    private let referenceNow = Date(timeIntervalSinceReferenceDate: 0)

    /// The engine identity these tests pin unless they are exercising a
    /// Settings switch. Held as a stored closure rather than written inline:
    /// `engineKey` is the init's last non-defaulted argument here, and a
    /// closure literal in that position reads as a trailing closure.
    private let fixedEngineKey: () -> String = { "test|model" }

    private func window(startingIn interval: TimeInterval) -> WarmMeetingWindow {
        WarmMeetingWindow(hasOngoingMeeting: false,
                          nextStart: referenceNow.addingTimeInterval(interval))
    }

    /// Isolated defaults with the preload key ABSENT — the shipping default
    /// (absent = ON). The shared `isolatedDefaults()` deliberately turns
    /// preloading OFF so the legacy recorder suites keep pinning the
    /// pre-warm-slot engine lifecycle; the warm tests undo that here, so this
    /// suite also proves an install that never touched the toggle gets the
    /// warm slot.
    private func warmDefaults() throws -> UserDefaults {
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: MeetingRecorderCenter.preloadBeforeMeetingsKey)
        return defaults
    }

    // MARK: - Park + reuse

    /// The headline reuse contract: record → stop → job completes → the engine
    /// is parked; a second recording takes it from the slot — the factory is
    /// called exactly ONCE across both recordings.
    func testEngineParksAfterJobAndSecondRecordingReusesIt() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let engine = ScriptedEngine(texts: ["one", "two"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engine)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertTrue(center.isEngineWarm, "a finished job must park its engine, not drop it")
        XCTAssertEqual(engineLoads, 1)

        await center.startRecording(eventID: nil, title: "Second", config: config)
        // The live pass takes the engine on its own task, shortly after start.
        await waitUntil("the warm engine to be taken by the live pass") { !center.isEngineWarm }
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(engineLoads, 1, "the second recording must reuse the parked engine — one load total")
        XCTAssertEqual(runner.savedTranscripts, ["one", "two"], "both recordings transcribe and save")
        XCTAssertTrue(center.isEngineWarm, "the engine parks again after the second job")
    }

    /// Preloading off = the old lifecycle: the engine is dropped at the end of
    /// the job (never parked), so the next recording loads afresh.
    func testToggleOffSkipsParkingAndNextRecordingLoadsFresh() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: MeetingRecorderCenter.preloadBeforeMeetingsKey)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertFalse(center.isEngineWarm, "with preloading off the job must not keep the engine")

        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(engineLoads, 2, "each recording loads its own engine when preloading is off")
    }

    /// The live-path release (test 8 of the design): a job whose live pass
    /// produced the transcript parks the handed-over engine and clears its
    /// own `transcriber` reference — even when the save then fails, the
    /// parked failure must not pin a second reference to what the warm slot
    /// now owns.
    func testLivePathJobParksEngineAndClearsJobReference() async throws {
        let recorder = FakeRecorder()
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["live one"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked")) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey
        )
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "Live", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        recorder.emitLive([Float](repeating: 0, count: 1600)) // one window → a live result
        await center.stopAndProcess(config: config)

        let job = try XCTUnwrap(center.jobs.first)
        XCTAssertTrue(job.phase.isFailed, "the save failed, so the job stays for retry")
        XCTAssertNil(job.transcriber, "the job must not keep a reference to the parked engine")
        XCTAssertTrue(center.isEngineWarm,
                      "the transcription succeeded, so the engine parks even though the save failed")
        XCTAssertEqual(engineLoads, 1)
    }

    /// A transcription failure drops the engine — a just-failed engine is
    /// never parked for the next recording to trip over.
    func testTranscriptionFailureDropsTheEngineInsteadOfParking() async throws {
        struct EngineError: Error {}
        final class ThrowingEngine: WhisperWindowEngine, @unchecked Sendable {
            func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 1.0] }
            func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
                throw EngineError()
            }
        }

        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ThrowingEngine(), supportsLive: false) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Broken", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertTrue(center.jobs.first?.phase.isFailed ?? false)
        XCTAssertFalse(center.isEngineWarm, "an engine that just failed must never be parked")
    }

    // MARK: - Poll: unload / hold

    /// The poll is the single unload point: a parked engine with no ongoing
    /// meeting and none starting within the lead is dropped on the next tick.
    func testPollUnloadsParkedEngineWhenNoMeetingNearby() async throws {
        var engineLoads = 0
        var meetings = WarmMeetingWindow.noMeetings
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in meetings }
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Meeting", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(center.isEngineWarm)

        // Hold while a meeting is ongoing…
        meetings = WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil)
        center.warmPolicyTick(config: config)
        XCTAssertTrue(center.isEngineWarm, "an ongoing meeting holds the warm engine")

        // …and while the next one starts within the lead…
        meetings = window(startingIn: 4 * 60)
        center.warmPolicyTick(config: config)
        XCTAssertTrue(center.isEngineWarm, "a meeting starting in ≤5 min holds the warm engine")

        // …but not for one comfortably beyond it.
        meetings = window(startingIn: 6 * 60)
        center.warmPolicyTick(config: config)
        XCTAssertFalse(center.isEngineWarm, "a meeting >5 min out does not hold the engine")
        XCTAssertEqual(engineLoads, 1, "unloading is a drop, never a reload")
    }

    /// Settings switched provider/model after the engine was parked: the poll
    /// unloads the stale engine even mid-meeting.
    func testPollUnloadsWarmEngineOnKeyMismatch() async throws {
        var currentKey = "whisperkit|large"
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["talk"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: { currentKey },
            now: { self.referenceNow },
            meetingsProvider: { _ in WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil) }
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Meeting", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(center.isEngineWarm)

        currentKey = "qwen3|omni"
        center.warmPolicyTick(config: config)
        XCTAssertFalse(center.isEngineWarm,
                       "a parked engine of the wrong provider/model is unloaded, meeting or not")
    }

    /// Same invalidation on the take path: a recording starting after a
    /// provider/model switch must load the newly selected engine, never be
    /// handed the stale parked one.
    func testTakeReloadsWhenParkedKeyIsStale() async throws {
        var currentKey = "whisperkit|large"
        let keyReader: () -> String = { currentKey }
        var engineLoads = 0
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk", "more talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: keyReader
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(center.isEngineWarm)

        currentKey = "qwen3|omni"
        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(engineLoads, 2, "a stale parked engine is dropped and the selected one loaded")
    }

    // MARK: - Poll: prewarm

    /// A meeting inside the lead pre-loads the engine, and a recording started
    /// while that load is still in flight awaits it and takes the result —
    /// exactly ONE factory call end to end.
    func testPollPrewarmsAndMidPrewarmRecordingReusesTheLoad() async throws {
        var engineLoads = 0
        var releaseLoad: CheckedContinuation<Void, Never>?
        let recorder = FakeRecorder()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                // Park the load until the test releases it, so a recording can
                // demonstrably start mid-prewarm.
                await withCheckedContinuation { releaseLoad = $0 }
                return TestTranscriber(ScriptedEngine(texts: ["prewarmed talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in self.window(startingIn: 3 * 60) }
        )
        let config = singleWindowConfig()

        center.warmPolicyTick(config: config)
        XCTAssertTrue(center.isPrewarming)
        await waitUntil("the prewarm to enter the engine factory") { releaseLoad != nil }
        XCTAssertEqual(engineLoads, 1)

        // Poll ticks while a prewarm is in flight must not start a second one.
        center.warmPolicyTick(config: config)
        XCTAssertEqual(engineLoads, 1, "one prewarm at a time")

        await center.startRecording(eventID: nil, title: "Meeting", config: config)
        XCTAssertEqual(engineLoads, 1, "the live pass awaits the prewarm instead of loading again")

        releaseLoad?.resume()
        await waitUntil("the live pass to take the prewarmed engine") {
            center.liveEngineState == .running
        }
        XCTAssertFalse(center.isEngineWarm, "the recording took the engine out of the slot")
        XCTAssertFalse(center.isPrewarming)

        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(engineLoads, 1, "one load covered the prewarm, the live pass, and the batch fallback")
        XCTAssertEqual(runner.savedTranscripts, ["prewarmed talk"])
    }

    /// The tick never prewarms while the engine is busy — the recording's own
    /// load path owns the slot.
    func testPollNeverPrewarmsWhileCapturing() async throws {
        var engineLoads = 0
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil) }
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Meeting", config: config)
        await waitUntil("the live pass to load its engine") { engineLoads == 1 }

        center.warmPolicyTick(config: config)
        XCTAssertFalse(center.isPrewarming, "a busy engine tick must never start a prewarm")
        XCTAssertEqual(engineLoads, 1)

        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)
    }

    /// A prewarm failure is silent and self-clearing: no crash, no user-facing
    /// error, `prewarmTask` cleared so a later tick retries — and a recording
    /// after the failed prewarm loads normally through the record-time path.
    func testPrewarmFailureIsSilentAndRecordingStillLoads() async throws {
        struct LoadError: Error {}
        var engineLoads = 0
        let recorder = FakeRecorder()
        let notifier = FakeNotifier()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                if engineLoads <= 2 { throw LoadError() }
                return TestTranscriber(ScriptedEngine(texts: ["recovered talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil) }
        )
        let config = singleWindowConfig()

        center.warmPolicyTick(config: config)
        await waitUntil("the failed prewarm to clear itself") { !center.isPrewarming }
        XCTAssertFalse(center.isEngineWarm)
        XCTAssertTrue(notifier.failedReasons.isEmpty, "a failed prewarm must never surface to the user")

        // The next tick simply retries (and fails again, still silently).
        center.warmPolicyTick(config: config)
        await waitUntil("the retried prewarm to clear itself") { !center.isPrewarming }
        XCTAssertEqual(engineLoads, 2)
        XCTAssertTrue(notifier.failedReasons.isEmpty)

        // Recording after the failed prewarms: the record-time load path works
        // exactly as without the feature.
        await center.startRecording(eventID: nil, title: "Meeting", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(engineLoads, 3)
        XCTAssertEqual(runner.savedTranscripts, ["recovered talk"])
    }

    /// The degenerate steady state: idle engine, empty calendar, toggle on —
    /// a tick does nothing at all (no prewarm, nothing to unload).
    func testIdleTickWithNoMeetingsIsANoOp() async throws {
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: []))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in .noMeetings }
        )

        center.warmPolicyTick(config: singleWindowConfig())

        XCTAssertFalse(center.isPrewarming)
        XCTAssertFalse(center.isEngineWarm)
        XCTAssertEqual(engineLoads, 0)
    }

    // MARK: - Poll loop

    /// The loop itself — the shape AppState starts in production, which the
    /// direct-tick tests above never exercise. Its first tick runs before the
    /// first sleep, so an ongoing meeting warms the engine without waiting out
    /// the 30-second interval; stopping the loop ends the decisions only, and
    /// leaves the parked engine where it is.
    func testPollLoopTicksOnStartAndStopEndsIt() async throws {
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: fixedEngineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil) }
        )

        center.startWarmPolicy()
        await waitUntil("the loop's first tick to warm the engine") { center.isEngineWarm }
        XCTAssertEqual(engineLoads, 1)

        center.stopWarmPolicy()
        XCTAssertTrue(center.isEngineWarm, "stopping the poll must not unload what is parked")
    }
}
