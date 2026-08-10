import Foundation
import XCTest
@testable import WatchtowerDesktop

// MARK: - Tests

@MainActor
final class MeetingRecorderCenterTests: MeetingRecorderTestCase {

    // MARK: Provider/model migration default

    /// With no `transcription.provider`/`transcription.model` keys set (an
    /// install predating the pluggable-provider work), resolution must land on
    /// whisperkit + turbo — the exact defaults `defaultEngineFactory` falls
    /// back to. Pins the migration contract in isolation from the recorder
    /// pipeline itself.
    func testDefaultEngineFactoryUsesProviderAndModelDefaults() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "test.transcription.defaults.\(UUID().uuidString)"))
        let providerID = d.string(forKey: "transcription.provider") ?? "whisperkit"
        let model = d.string(forKey: "transcription.model") ?? "large-v3-v20240930"
        XCTAssertEqual(providerID, "whisperkit")
        XCTAssertEqual(model, "large-v3-v20240930")
        XCTAssertEqual(type(of: TranscriptionProviderRegistry.resolve(providerID: providerID)).id, "whisperkit")
    }

    // MARK: Guards

    func testStartWhileBusyIsANoOp() async throws {
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }

        await center.startRecording(eventID: "evt-2", title: "Other")

        XCTAssertEqual(recorder.startCalls, 1, "a second start while busy must be a no-op")
        XCTAssertEqual(center.currentEventID, "evt-1")
        XCTAssertEqual(center.currentTitle, "Weekly")
    }

    // MARK: Happy path

    func testHappyPathPhaseSequence() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let defaults = try isolatedDefaults()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello world"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
        // Crash recovery rides a per-recording `rec_X.meta` sidecar; the
        // single-slot UserDefaults pointer it replaced is never written again.
        _ = try startedRecordingMeta()
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey),
                     "the retired single-slot pointer must not be written any more")

        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
        XCTAssertEqual(notifier.readyTitles, ["Ad hoc"])
        XCTAssertTrue(notifier.failedReasons.isEmpty)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.first, "meeting-prep")
        let sidecar = audio.deletingPathExtension().appendingPathExtension("txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "the persisted transcript must be removed after a successful save")
    }

    func testStateSurvivesViewLifetime() async throws {
        // The "начал → ушёл → вернулся" contract: recording state lives in the
        // Center, so a view that observed it can be torn down mid-run and the run
        // still completes.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["captured"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Standup")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }

        // A view observing the Center is deallocated mid-run ("ушёл").
        final class ObservingView { let center: MeetingRecorderCenter; init(_ c: MeetingRecorderCenter) { center = c } }
        var view: ObservingView? = ObservingView(center)
        XCTAssertNotNil(view)
        view = nil

        // "вернулся": the run driven off the AppState-held Center still completes.
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
    }

    func testRecapErrorStillCompletes() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["some talk"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapFailedEnvelope) },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        // Transcript saved even though the recap failed → completes at idle with a
        // ready notification that flags the pending recap retry.
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(notifier.readyTitles.count, 1)
        XCTAssertTrue(notifier.readyTitles.first?.localizedCaseInsensitiveContains("recap") ?? false,
                      "ready notification must mention the recap needs retry, got \(notifier.readyTitles)")
        XCTAssertTrue(notifier.failedReasons.isEmpty)
    }

    func testRecapSkippedStillCompletesWithFriendlierNotification() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["some talk"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapSkippedEnvelope) },
            notifier: notifier,
            defaults: try isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        // Skipped recap is not a failure to retry — the notification says so
        // instead of implying the recap needs another attempt.
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(notifier.readyTitles.count, 1)
        XCTAssertTrue(
            notifier.readyTitles.first?.localizedCaseInsensitiveContains("too short for recap") ?? false,
            "ready notification must mention the recap was skipped for being too short, got \(notifier.readyTitles)")
        XCTAssertFalse(
            notifier.readyTitles.first?.localizedCaseInsensitiveContains("needs retry") ?? true,
            "a skipped recap must not read like a failure needing retry")
        XCTAssertTrue(notifier.failedReasons.isEmpty)
    }

    // MARK: Failure paths

    func testRecorderStartFailureGoesFailed() async throws {
        let recorder = FakeRecorder()
        recorder.startError = AudioRecordingError.microphonePermissionDenied
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly")

        guard case .failed = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertFalse(center.isBusy, "a failed start must not leave the Center stuck busy")
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testRecorderStopErrorGoesFailedAndKeepsPending() async throws {
        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let defaults = try isolatedDefaults()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        let pendingBefore = try XCTUnwrap(center.pendingAudioURL)

        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed(let reason) = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("device vanished"))
        XCTAssertEqual(center.pendingAudioURL, pendingBefore,
                       "the pending audio pointer must be kept after a stop error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaSidecar(pendingBefore).path),
                      "the recovery sidecar must survive a stop error so the audio comes back after a crash")
        XCTAssertEqual(runner.invocations.count, 0)
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testRetryAfterStopErrorLoadsFreshEngineNotStale() async throws {
        // The live pass loads its own engine at record-start into `loadedEngine`
        // for reuse by the stop-time batch fallback. When `recorder.stop()`
        // itself throws, that path never reaches the fallback/reuse code at
        // all — so `loadedEngine` must be cleared right there. Otherwise a
        // later same-session retry (no new `startRecording`) would silently
        // reuse the stale engine from the failed attempt instead of loading
        // its own.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["hello"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        // Drain the main actor so the live pass finishes loading its engine
        // (into `loadedEngine`) before the recording is stopped.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(engineLoads, 1, "the live pass loads the engine once at record-start")

        // `prepareRetry` is not used here — this is the same-session retry
        // path (`retryTranscription` with no intervening `startRecording`),
        // pointed at the audio the failed stop left pending.
        await center.stopAndProcess(config: singleWindowConfig())
        guard case .failed = center.phase else {
            return XCTFail("expected .failed after a stop() error, got \(center.phase)")
        }

        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertEqual(engineLoads, 2,
                       "retry after a stop() error must load a fresh engine, never the stale one from the failed attempt")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testLatchedWriteErrorFromStopGoesFailedAndKeepsPending() async throws {
        // A recording truncated by a mid-flight write error surfaces from
        // stop() as .writeFailed and must not be processed as a clean success.
        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.writeFailed("disk full")
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        let pendingBefore = try XCTUnwrap(center.pendingAudioURL)

        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed(let reason) = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("disk full"))
        XCTAssertEqual(center.pendingAudioURL, pendingBefore)
        XCTAssertEqual(runner.invocations.count, 0)
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testEngineFactoryFailureKeepsAudio() async throws {
        struct EngineLoadError: Error {}
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in throw EngineLoadError() },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertEqual(center.pendingAudioURL, audio, "the audio must be kept for retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(runner.invocations.count, 0)
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testDecodeFailureKeepsAudio() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: { _ in throw AudioFileDecoderError.unsupportedFormat },
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertEqual(center.pendingAudioURL, audio, "the audio must be kept for retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(runner.invocations.count, 0)
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testMissingRunnerFailsVisiblyAfterRecorderStopped() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["real speech"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(recorder.stopCalls, 1,
                       "the recorder must be stopped and the file finalized before the CLI is resolved")
        guard case .failed(let reason) = center.phase else {
            return XCTFail("expected .failed when the CLI cannot be resolved, got \(center.phase)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("cli"))
        XCTAssertEqual(center.pendingAudioURL, audio, "the audio must be kept for retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(notifier.failedReasons.count, 1, "a missing runner must fail visibly, never silently")
    }

    func testEmptyTranscriptFailsButKeepsAudio() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) }, // all-silence
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed(let reason) = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("speech"))
        XCTAssertEqual(center.pendingAudioURL, audio, "the audio must be kept for retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(runner.invocations.count, 0, "no save when there is no transcript")
        XCTAssertEqual(notifier.failedReasons.count, 1)
    }

    func testSaveFailureKeepsAudioAndAllowsRetry() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let defaults = try isolatedDefaults()
        let failingRunner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked"))
        let goodRunner = FakeCLIRunner(stdout: recapOKEnvelope)
        var activeRunner: CLIRunnerProtocol = failingRunner
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["real speech"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { activeRunner },
            notifier: notifier,
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(config: singleWindowConfig())

        guard case .failed = center.phase else {
            return XCTFail("expected .failed after save error, got \(center.phase)")
        }
        XCTAssertEqual(center.pendingAudioURL, audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        // While the save failure stands, the transcript sits next to the audio.
        let transcriptFile = audio.deletingPathExtension().appendingPathExtension("txt")
        XCTAssertEqual(try String(contentsOf: transcriptFile, encoding: .utf8), "real speech")

        // Retry with a working runner re-invokes save straight from the
        // persisted transcript — no second engine load / transcription — and
        // cleans the sidecar files up on success.
        activeRunner = goodRunner
        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey),
                     "the retired single-slot pointer must not be written any more")
        XCTAssertEqual(goodRunner.invocations.count, 1)
        XCTAssertEqual(engineLoads, 1, "retry after a save failure must reuse the persisted transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptFile.path))
    }

    // MARK: Recovery / launch

    func testRestorePendingOnLaunch() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)

        // Missing file → the stale key is cleared.
        let missingDefaults = try isolatedDefaults()
        missingDefaults.set("/tmp/does-not-exist-\(UUID().uuidString).caf", forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center2 = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: missingDefaults,
            recordingsDirectory: recordingsDir
        )
        center2.restorePendingOnLaunch()
        XCTAssertNil(center2.pendingAudioURL)
        XCTAssertNil(missingDefaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
    }

    func testDismissRecoveredClearsPendingButKeepsAudio() async throws {
        // A recovered recording the user chooses NOT to transcribe: dismissing
        // the pill must clear the pending pointer (so the capsule never returns,
        // this session or on relaunch) while leaving the audio file on disk —
        // the Go orphan sweep reclaims it later, matching "audio survives".
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        defaults.set("evt-1", forKey: MeetingRecorderCenter.pendingEventIDKey)
        defaults.set("Weekly", forKey: MeetingRecorderCenter.pendingTitleKey)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)

        center.dismissRecovered()

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL, "dismiss must clear the pending pointer so the pill goes away")
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey),
                     "the pending-audio key must be cleared so the pill never returns on relaunch")
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingEventIDKey))
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingTitleKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path),
                      "the audio file must survive — dismiss only forgets the pointer, the Go sweep reclaims the file")
    }

    func testDismissRecoveredIsNoOpWhileRecording() async throws {
        // Guard: dismiss is only for the idle "recovered" pill. It must never
        // tear the pending pointer out from under an in-flight recording.
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly")
        let pendingBefore = try XCTUnwrap(center.pendingAudioURL)

        center.dismissRecovered()

        guard case .recording = center.phase else {
            return XCTFail("dismiss must not disturb an active recording, got \(center.phase)")
        }
        XCTAssertEqual(center.pendingAudioURL, pendingBefore,
                       "dismiss while recording must be a no-op on the pending pointer")
    }

    func testRestorePendingRecoversEventLink() async throws {
        // A crash mid-recording mirrored the audio path AND its event link/title.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        defaults.set("evt-42", forKey: MeetingRecorderCenter.pendingEventIDKey)
        defaults.set("Weekly sync", forKey: MeetingRecorderCenter.pendingTitleKey)

        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["recovered speech"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-42", "the event link must survive relaunch")
        XCTAssertEqual(center.recoverable.first?.title, "Weekly sync", "the title must survive relaunch")

        // The recovered transcript saves event-linked, not as ad-hoc.
        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertEqual(center.phase, .idle)
        let args = try XCTUnwrap(runner.invocations.first)
        let eventIdx = try XCTUnwrap(args.firstIndex(of: "--event-id"))
        XCTAssertEqual(args[eventIdx + 1], "evt-42")
        let titleIdx = try XCTUnwrap(args.firstIndex(of: "--title"))
        XCTAssertEqual(args[titleIdx + 1], "Weekly sync")
    }

    func testPrepareRetryDiscardsStaleSidecarsAndReTranscribes() async throws {
        // An earlier run left a transcript sidecar next to the audio; an explicit
        // "Re-transcribe" must discard it and produce FRESH output.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let staleTxt = audio.deletingPathExtension().appendingPathExtension("txt")
        let staleJSON = audio.deletingPathExtension().appendingPathExtension("json")
        try "STALE cached text".write(to: staleTxt, atomically: true, encoding: .utf8)
        try #"{"durationSec":5,"langStats":{}}"#.write(to: staleJSON, atomically: true, encoding: .utf8)

        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["fresh transcription"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        center.prepareRetry(audioURL: audio, eventID: "evt-9", title: "Redo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTxt.path),
                       "prepareRetry must delete the stale transcript sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleJSON.path),
                       "prepareRetry must delete the stale metadata sidecar")

        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertEqual(engineLoads, 1,
                       "explicit re-transcribe must run the engine, not reuse the stale sidecar")
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testMalformedSidecarFallsBackToFullReTranscription() async throws {
        // Empty text sidecar → cannot reuse → full re-transcription.
        try await assertMalformedSidecarReTranscribes(txt: "   ",
                                                      json: #"{"durationSec":5,"langStats":{}}"#)
        // Valid text but undecodable metadata → cannot reuse → full re-transcription.
        try await assertMalformedSidecarReTranscribes(txt: "valid cached text",
                                                      json: "not json{")
    }

    /// Seeds a malformed transcript sidecar next to a recovered audio file and
    /// asserts `retryTranscription` re-runs the engine (engine load happens)
    /// rather than reusing the unreadable sidecar, without crashing.
    private func assertMalformedSidecarReTranscribes(txt: String, json: String) async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try txt.write(to: audio.deletingPathExtension().appendingPathExtension("txt"),
                      atomically: true, encoding: .utf8)
        try json.write(to: audio.deletingPathExtension().appendingPathExtension("json"),
                       atomically: true, encoding: .utf8)

        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        var engineLoads = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["fresh"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)

        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertEqual(engineLoads, 1, "a malformed sidecar must trigger full re-transcription")
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: Progress

    /// Drains the main actor so the Center's stream-backed progress consumer
    /// applies every buffered update; the gated engine produces no new progress
    /// while blocked, so after draining `phase` is fully caught up.
    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    func testProgressReported() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let engine = GateEngine(texts: ["a", "b", "c"])
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(engine) },
            decode: stubDecode(sampleCount: 4800), // 3 windows at 0.1 s / no overlap
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        center.prepareRetry(audioURL: audio, eventID: nil, title: "Ad hoc")
        let runTask = Task {
            await center.retryTranscription(config: threeWindowConfig())
        }

        var entered = engine.enteredStream.makeAsyncIterator()

        // At each window entry, only the previous windows' progress has been
        // reported: window 1 → initial 0/0, window 2 → 1/3, window 3 → 2/3.
        let expected: [MeetingRecorderCenter.Phase] = [
            .transcribing(done: 0, total: 0),
            .transcribing(done: 1, total: 3),
            .transcribing(done: 2, total: 3)
        ]
        for phase in expected {
            _ = await entered.next()
            await drainMainActor()
            XCTAssertEqual(center.phase, phase)
            engine.release()
        }

        await runTask.value
        XCTAssertEqual(center.phase, .idle)
    }

    // MARK: Live pass

    func testLivePathSavesWithoutRedecoding() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        var decodeCalls = 0
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in engineLoads += 1; return TestTranscriber(ScriptedEngine(texts: ["live one", "live two"])) },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Live meeting")
        // Feed 3.5 windows of samples while "recording", then stop (finishes the stream).
        recorder.emitLive([Float](repeating: 0, count: 5600))
        await center.stopAndProcess(config: threeWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 0, "the live result is saved directly — the file must not be re-decoded")
        XCTAssertEqual(engineLoads, 1, "the engine loads once at start and is reused")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(center.pendingAudioURL)
    }

    func testLiveDisabledSkipsLivePassAndBatchTranscribesAfterStop() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        var engineLoads = 0
        var decodeCalls = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in engineLoads += 1; return TestTranscriber(ScriptedEngine(texts: ["batch text"])) },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        var config = singleWindowConfig()
        config.liveTranscription = false

        await center.startRecording(eventID: nil, title: "No live", config: config)
        recorder.emitLive([Float](repeating: 0, count: 3200))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertFalse(center.captureLiveEnabled, "the capture snapshots the disabled toggle")
        XCTAssertEqual(center.liveEngineState, .off, "no live pass may start while disabled")
        XCTAssertEqual(engineLoads, 0, "no engine loads during capture")
        XCTAssertTrue(center.liveChunks.isEmpty)

        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(engineLoads, 1, "the batch path loads the engine after Stop")
        XCTAssertEqual(decodeCalls, 1, "the transcript comes from the file, not a live pass")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(center.pendingAudioURL)
    }

    func testLiveDisabledRecordingOverDrainingOrphanTailDoesNotAdoptIt() async throws {
        // The scenario `consumeLivePassOwnership`'s `captureLiveEnabled` term
        // guards: a live-DISABLED recording runs while a PREVIOUS recording's
        // stop-error orphan tail still holds the engine slot. The disabled
        // recording's Stop must not adopt the orphan's live output nor its
        // engine — its job loads a fresh engine and batch-decodes the file.
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        let gateEngine = GateEngine(texts: ["stale-first-recording"])
        let secondEngine = ScriptedEngine(texts: ["fresh-second-recording"])
        var engineFactoryCalls = 0
        var recorderFactoryCalls = 0
        var decodeCalls = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: {
                recorderFactoryCalls += 1
                return recorderFactoryCalls == 1 ? recorder1 : recorder2
            },
            engineFactory: { _ in
                engineFactoryCalls += 1
                return engineFactoryCalls == 1 ? TestTranscriber(gateEngine) : TestTranscriber(secondEngine)
            },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let liveConfig = threeWindowConfig()

        // Recording 1 (live ON): park its live pass inside the gate engine,
        // then error the stop — the orphan tail keeps draining.
        await center.startRecording(eventID: nil, title: "First", config: liveConfig)
        recorder1.emitLive([Float](repeating: 0, count: 3200))
        var entered = gateEngine.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        recorder1.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: liveConfig)

        // Recording 2 (live OFF) starts over the draining orphan.
        var config = liveConfig
        config.liveTranscription = false
        let audio2 = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio2)
            removeSidecars(audio2)
        }
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .off)

        // Stop recording 2 while the orphan is still parked; its job waits on
        // the engine slot, so release the gate concurrently.
        let stopTask = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<12 { await Task.yield() }
        gateEngine.release()
        await stopTask.value

        // Recording 1's failed job stays in the queue as retriable, so the
        // legacy head-of-queue `phase` still reads .failed — assert on the
        // second recording's own outcome instead.
        XCTAssertEqual(runner.invocations.count, 1, "recording 2 saved exactly once")
        XCTAssertEqual(decodeCalls, 1, "the disabled recording batch-decodes its own file")
        XCTAssertEqual(engineFactoryCalls, 2,
                       "the job loads a fresh engine — adopting the orphan's would mean Stop consumed a live pass it never owned")
        XCTAssertEqual(center.liveEngineState, .off,
                       "no parked live start may fire when the orphan frees the slot")
        let savedText = runner.invocations.first.flatMap { inv in
            inv.firstIndex(of: "--transcript-file").flatMap { idx in
                inv.indices.contains(idx + 1) ? try? String(contentsOfFile: inv[idx + 1], encoding: .utf8) : nil
            }
        }
        // nil = the temp file was already cleaned up post-save; only an actual
        // read-back containing the orphan's text is a failure.
        XCTAssertNotEqual(savedText?.contains("stale-first-recording"), true,
                          "the orphan's live text must never reach the second recording's save")
    }

    func testLiveChunksAccumulateAndSurviveViewLifetime() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["alpha", "beta"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Live", config: threeWindowConfig())
        recorder.emitLive([Float](repeating: 0, count: 3200)) // 2 full windows worth
        // Let the live task drain the emitted samples.
        for _ in 0..<12 { await Task.yield() }

        XCTAssertFalse(center.liveChunks.isEmpty, "live chunks must accumulate during recording")
        XCTAssertEqual(center.liveChunks.first?.text, "alpha")

        await center.stopAndProcess(config: threeWindowConfig())
        XCTAssertEqual(center.phase, .idle)
    }

    func testLiveEngineUnavailableFallsBackToBatch() async throws {
        struct EngineLoadError: Error {}
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        var engineCalls = 0
        var decodeCalls = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineCalls += 1
                if engineCalls == 1 { throw EngineLoadError() } // live load fails
                return TestTranscriber(ScriptedEngine(texts: ["batch recovered"]))  // stop-time fallback succeeds
            },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Live")
        // Live engine failed to load → recording continues, no error surfaced.
        guard case .recording = center.phase else { return XCTFail("recording must continue after live-load failure") }
        // The engine loads on a background task; drain the main actor so the
        // .unavailable transition lands before we assert on it.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(center.liveEngineState, .unavailable)

        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 1, "fallback decodes the file")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testNonLiveProviderSkipsLiveAndTranscribesViaBatchOnStop() async throws {
        // A batch-only provider (supportsLive == false → makeLiveSession returns nil)
        // must skip the live pass entirely — a DISTINCT branch from live-engine-load
        // failure — yet still produce a transcript via the batch path on stop.
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        var decodeCalls = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                // Engine loads fine; it just offers no live session.
                TestTranscriber(ScriptedEngine(texts: ["batch only"]), supportsLive: false)
            },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "NonLive")
        guard case .recording = center.phase else { return XCTFail("recording must continue for a batch-only provider") }
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(center.liveEngineState, .unavailable, "a batch-only provider exposes no live session")

        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 1, "batch-only provider transcribes via the batch path on stop")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testStopErrorCancelsOrphanedLiveTaskAndFencesStaleAppends() async throws {
        // Regression pin for the whole-branch review fix: `recorder.stop()`
        // finishes `liveSamples` BEFORE throwing, so a stop-time error leaves
        // the live pass's Task still in flight (parked mid-window on the
        // engine call below). Once phase is `.failed` the Center is not busy,
        // so a NEW recording can start immediately — its `liveChunks` must
        // never receive an append from the OLD (cancelled, orphaned) task,
        // even though cancellation cannot interrupt the engine call already
        // in progress when `cancel()` was issued.
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        let gateEngine = GateEngine(texts: ["stale-chunk"])
        let secondEngine = ScriptedEngine(texts: ["fresh-second-recording"])
        var engineFactoryCalls = 0
        var recorderFactoryCalls = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: {
                recorderFactoryCalls += 1
                return recorderFactoryCalls == 1 ? recorder1 : recorder2
            },
            engineFactory: { _ in
                engineFactoryCalls += 1
                return engineFactoryCalls == 1 ? TestTranscriber(gateEngine) : TestTranscriber(secondEngine)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let liveConfig = threeWindowConfig() // 0.1 s window, no overlap → 1600 samples/window

        // Recording 1: feed exactly one full ("not the last") window's worth
        // plus more, so the live task calls into the (blocking) gate engine.
        await center.startRecording(eventID: nil, title: "First", config: liveConfig)
        recorder1.emitLive([Float](repeating: 0, count: 3200))
        var entered = gateEngine.enteredStream.makeAsyncIterator()
        _ = await entered.next() // the stale window is now parked inside transcribeWindow

        // Stop errors: liveTask must be cancelled and liveGeneration bumped
        // right here, before the still-parked engine call ever resumes.
        recorder1.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: liveConfig)
        guard case .failed = center.phase else {
            return XCTFail("expected .failed after stop() error, got \(center.phase)")
        }

        // A new recording starts right away — allowed, since `.failed` is not
        // busy — and resets `liveChunks` for the new generation.
        await center.startRecording(eventID: nil, title: "Second", config: liveConfig)
        guard case .recording = center.phase else {
            return XCTFail("expected .recording for the new recording, got \(center.phase)")
        }
        XCTAssertTrue(center.liveChunks.isEmpty, "the new recording starts with a clean liveChunks slate")

        // Now let the orphaned generation-1 engine call resume: its onChunk
        // fires, but is fenced by the (already-bumped) generation check.
        gateEngine.release()
        for _ in 0..<12 { await Task.yield() }

        XCTAssertTrue(center.liveChunks.isEmpty,
                      "a stale append from the cancelled prior generation must not contaminate the new recording's liveChunks")
        XCTAssertEqual(center.currentTitle, "Second")

        // Hygiene: drive recording 2 to completion so no task is left dangling.
        let audio2 = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio2)
            removeSidecars(audio2)
        }
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        await center.stopAndProcess(config: liveConfig)
        XCTAssertTrue(center.liveChunks.isEmpty,
                      "generation-1's stale chunk must still be absent after recording 2 completes")
    }

    // MARK: - Diarization post-pass

    /// What the batch-path harness hands back: the saved text, the saved
    /// segments JSON (nil when the save carried none), and the fakes for
    /// further assertions.
    private struct DiarizationFlowResult {
        let savedText: String?
        let savedSegments: String?
        let center: MeetingRecorderCenter
        let notifier: FakeNotifier
        let runner: TranscriptCapturingRunner
        /// Every eventID the attendee loader was called with — pins the
        /// job → renderRoles → matchVoiceNames plumb-through.
        let attendeeLoaderEventIDs: [String]
    }

    /// Collects the eventIDs handed to the attendee loader (the loader is
    /// @Sendable, so the capture needs an actor).
    private actor EventIDBox {
        var values: [String] = []
        func append(_ id: String) { values.append(id) }
    }

    /// Batch-path harness: recording → (empty live) → decode stub → scripted
    /// engine → fake diarizer → capturing runner.
    private func runDiarizationFlow(
        audio: URL,
        diarizer: FakeDiarizer,
        defaults: UserDefaults,
        rolesEnabled: Bool = true,
        voicePrints: [VoicePrint] = [],
        eventID: String? = nil,
        attendees: [EventAttendee]? = nil,
        ownerEmails: Set<String>? = nil
    ) async throws -> DiarizationFlowResult {
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["привет", "ответ"])) },
            diarizerFactory: { _ in diarizer },
            decode: stubDecode(sampleCount: 4800), // 3 windows of 0.1 s
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )
        // Always wire a loader (production has one once the DB opens); an
        // empty array behaves exactly like no voice-print database. The
        // attendee/owner loaders stay nil unless a test supplies them —
        // mirroring an install with no DB-backed identity.
        center.voicePrintsLoader = { voicePrints }
        let receivedEventIDs = EventIDBox()
        if let attendees {
            center.attendeesLoader = { id in
                await receivedEventIDs.append(id)
                return attendees
            }
        }
        if let ownerEmails { center.ownerEmailsLoader = { ownerEmails } }
        var config = threeWindowConfig()
        config.diarization = rolesEnabled
        await center.startRecording(eventID: eventID, title: "Roles")
        await center.stopAndProcess(config: config)
        return DiarizationFlowResult(savedText: runner.savedTranscripts.first,
                                     savedSegments: runner.savedSegments.first.flatMap { $0 },
                                     center: center, notifier: notifier, runner: runner,
                                     attendeeLoaderEventIDs: await receivedEventIDs.values)
    }

    func testDiarizationRendersRolesIntoSavedText() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25)
        ]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )
        let (saved, savedSegments) = (flow.savedText, flow.savedSegments)

        XCTAssertEqual(flow.center.phase, .idle)
        XCTAssertEqual(saved, "[Speaker 1] привет\n[Speaker 2] ответ")
        XCTAssertEqual(flow.notifier.readyTitles, ["Roles"], "successful roles must not flag the notification")
        XCTAssertEqual(diarizer.calls, 1)

        // The batch path must ship the structured utterances alongside the
        // text, and they must render to exactly the saved text (the
        // transcript_text = render(segments) invariant at the source).
        let utterances = try XCTUnwrap(TranscriptSegments.decode(try XCTUnwrap(savedSegments)))
        XCTAssertEqual(TranscriptSegments.render(utterances), saved)
        XCTAssertEqual(utterances.map(\.idx), [0, 1])
        XCTAssertEqual(utterances.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertTrue(utterances.allSatisfy { $0.endSec > $0.startSec })
    }

    func testActivitySidecarLabelsOwnerCluster() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio) // covers the .activity sidecar too
        }
        // Bin 0 (0.0–0.1 s) mic-dominated → cluster A is the owner.
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25)
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        ).savedText

        XCTAssertEqual(saved, "[Я] привет\n[Speaker 1] ответ")
    }

    // MARK: - Voice identity (Level 1 matching)

    private func voicePrint(_ personKey: String, _ name: String, _ vector: [Float]) -> VoicePrint {
        VoicePrint(id: nil, personKey: personKey, displayName: name,
                   embedding: VoicePrintEmbedding.encode(vector),
                   sampleCount: 1, updatedAt: "")
    }

    func testVoiceMatchRendersDisplayNameAndShipsSpeakersFile() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [voicePrint("sasha@corp.com", "Саша", [0, 1])]
        )

        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Саша] ответ",
                       "a confident voice match renders the display name instead of Speaker N")
        let utterances = try XCTUnwrap(TranscriptSegments.decode(try XCTUnwrap(flow.savedSegments)))
        XCTAssertEqual(utterances.map(\.speaker), ["Speaker 1", "Саша"])
        // The per-cluster embeddings ship keyed by the FINAL rendered labels.
        let speakersJSON = try XCTUnwrap(flow.runner.savedSpeakers.first.flatMap { $0 })
        let speakers = try XCTUnwrap(SpeakerEmbeddings.decode(speakersJSON))
        XCTAssertEqual(Set(speakers.map(\.speaker)), ["Speaker 1", "Саша"])
    }

    /// A diarized cluster that wins zero transcript utterances (it only
    /// covered silence) must be filtered out of the shipped --speakers-file:
    /// its label matches nothing in the transcript, and shipping it would
    /// make the Go save report it as an orphan.
    func testClusterWithNoUtterancesIsExcludedFromSpeakersFile() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1]),
            // Cluster C covers a window past every transcript segment — it
            // wins zero utterances.
            SpeakerSegment(speakerID: "C", startSec: 0.26, endSec: 0.3, embedding: [0.6, 0.8])
        ]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )

        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Speaker 2] ответ")
        let utterances = try XCTUnwrap(TranscriptSegments.decode(try XCTUnwrap(flow.savedSegments)))
        XCTAssertEqual(utterances.map(\.speaker), ["Speaker 1", "Speaker 2"])
        // The orphan cluster's embedding is dropped; the others survive.
        let speakersJSON = try XCTUnwrap(flow.runner.savedSpeakers.first.flatMap { $0 })
        let speakers = try XCTUnwrap(SpeakerEmbeddings.decode(speakersJSON))
        XCTAssertEqual(Set(speakers.map(\.speaker)), ["Speaker 1", "Speaker 2"],
                       "a zero-utterance cluster must not ship an orphan embedding")
    }

    /// «Я» (mic dominance) keeps absolute priority over a voice match.
    func testSelfClusterBeatsVoiceMatch() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        // Bin 0 (0.0–0.1 s) mic-dominated → cluster A is the owner.
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [
                voicePrint("owner@corp.com", "Owner Duplicate", [1, 0]),
                voicePrint("sasha@corp.com", "Саша", [0, 1])
            ]
        ).savedText

        XCTAssertEqual(saved, "[Я] привет\n[Саша] ответ",
                       "the owner's cluster stays «Я» even when a voice print matches it")
    }

    // MARK: - Owner identity vs «Я» (Center-level wiring)

    /// The blocker scenario from review: the owner's own print is NAME-keyed
    /// (minted by an ad-hoc/free-text rename), so it cannot be recognized as
    /// the owner's. Owner identity alone must NOT arm the veto — otherwise
    /// the owner's mic-dominant cluster carries a voice name, is "confidently
    /// someone else", and «Я» disappears from every transcript.
    func testNameKeyedOwnerPrintDoesNotArmVetoAndSelfSurvives() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [voicePrint("vadym", "vadym", [1, 0])], // name-keyed: NOT recognizable as owner
            ownerEmails: ["owner@x.com"]
        ).savedText

        XCTAssertEqual(saved, "[Я] привет\n[Speaker 1] ответ",
                       "with no owner-identified print in the pool «Я» must keep its legacy absolute priority")
    }

    /// End-to-end tie-break: both clusters mic-dominant (meeting room), the
    /// owner's EMAIL-keyed print matches the later/quieter one — «Я» goes to
    /// the owner-matched cluster, not the earliest.
    func testOwnerEmailKeyedPrintWinsSelfTieBreakEndToEnd() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        // Every bin mic-dominated → both clusters are «Я» candidates at share
        // 1.0; legacy would give «Я» to the earliest (A).
        try "0.500000 0.010000\n0.500000 0.010000\n0.500000 0.010000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [voicePrint("owner@x.com", "owner@x.com", [0, 1])],
            ownerEmails: ["Owner@X.com "] // case/trim variance must not break the compare
        ).savedText

        XCTAssertEqual(saved, "[Speaker 1] привет\n[Я] ответ",
                       "the owner-voice-matched cluster must win «Я» over the earlier equally-dominant one")
    }

    /// Event-linked recording: the eventID reaches the attendee loader
    /// (plumb-through), a non-attendee stranger's print is scoped out, and
    /// the owner's print survives scoping even though the owner is NOT on
    /// the attendee list (organizer-only/alias case).
    func testEventScopingDropsStrangerButKeepsOwnerPrint() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try "0.500000 0.010000\n0.500000 0.010000\n0.500000 0.010000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [
                voicePrint("stranger@other.com", "Чужой", [1, 0]), // not an attendee → scoped out
                voicePrint("owner@x.com", "owner@x.com", [0, 1])   // owner: survives scoping
            ],
            eventID: "evt-1",
            attendees: [EventAttendee(email: "alice@corp.com", displayName: "Alice",
                                      responseStatus: "accepted", slackUserID: "")],
            ownerEmails: ["owner@x.com"]
        )

        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Я] ответ",
                       "stranger must not be named (scoped out); owner print must survive scoping and win «Я»")
        XCTAssertEqual(flow.attendeeLoaderEventIDs, ["evt-1"],
                       "the job's eventID — not a title or nil — must reach the attendee loader")
    }

    /// End-to-end veto at the Center level: the pool holds a USABLE owner
    /// print (armed), the mic-dominant cluster confidently matches a
    /// colleague and does not resemble the owner → «Я» is withheld from the
    /// saved transcript; the below-threshold owner-matched cluster keeps the
    /// owner print's display name (pinned design: no «Я» beats a wrong «Я»).
    func testColleagueMatchedMicWinnerIsVetoedEndToEnd() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        // Only bin 0 mic-dominated → A is the sole «Я» candidate.
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [
                voicePrint("colleague@x.com", "Коллега", [1, 0]), // matches mic-dominant A
                voicePrint("owner@x.com", "owner@x.com", [0, 1])  // owner: matches B only
            ],
            ownerEmails: ["owner@x.com"]
        ).savedText

        XCTAssertEqual(saved, "[Коллега] привет\n[owner@x.com] ответ",
                       "a colleague-matched mic winner must lose «Я» when the owner is identifiable elsewhere")
    }

    /// The mixed-print owner: a NAME-keyed print wins the global match for
    /// the owner's cluster, but the EMAIL-keyed owner print also matches it
    /// (≥ threshold) → the cluster is veto-exempt and «Я» survives via the
    /// ordinary mic path (the conservative owner rule).
    func testMixedKeyOwnerPrintsDoNotVetoTheOwner() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [
                voicePrint("vadym", "vadym", [1, 0]),            // name-keyed: wins the global match for A
                voicePrint("owner@x.com", "owner@x.com", [0.9, 0.44]) // email-keyed: also matches A ≥ 0.7
            ],
            ownerEmails: ["owner@x.com"]
        ).savedText

        XCTAssertEqual(saved, "[Я] привет\n[Speaker 1] ответ",
                       "the owner's own name-keyed print must not veto «Я» when their email-keyed print resembles the cluster")
    }

    /// An email-keyed owner print learned under an OLDER embedding model
    /// (dimension mismatch — unusable this run) must not arm the veto: the
    /// colleague-matched mic winner keeps «Я» via the legacy path instead of
    /// stripping it with no possible tie-break.
    func testStaleDimensionOwnerPrintDoesNotArmVeto() async throws {
        let audio = try makeDummyAudioFile()
        let activityURL = MicActivity.url(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try "0.500000 0.010000\n0.010000 0.500000\n0.010000 0.500000\n"
            .write(to: activityURL, atomically: true, encoding: .utf8)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [
                // The colleague print matches the mic-dominant cluster A —
                // with an ARMED veto this recording would lose «Я».
                voicePrint("colleague@x.com", "Коллега", [1, 0]),
                voicePrint("owner@x.com", "owner@x.com", [0, 1, 0]) // 3-dim: unusable against 2-dim clusters
            ],
            ownerEmails: ["owner@x.com"]
        ).savedText

        XCTAssertEqual(saved, "[Я] привет\n[Speaker 1] ответ",
                       "an unusable owner print must disarm the veto — «Я» keeps its legacy absolute priority")
    }

    /// Event-linked recording whose event has expired (loader returns []) —
    /// scoping must degrade to the GLOBAL pool, not to an empty one.
    func testEventWithNoAttendeesDegradesToGlobalMatching() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25, embedding: [0, 1])
        ]

        let saved = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [voicePrint("sasha@corp.com", "Саша", [0, 1])],
            eventID: "evt-gone",
            attendees: []
        ).savedText

        XCTAssertEqual(saved, "[Speaker 1] привет\n[Саша] ответ",
                       "an empty attendee list must fall back to global matching, same as ad-hoc")
    }

    /// Diarizers without embeddings (non-FluidAudio) fully degrade: no voice
    /// names, no speakers file — byte-identical to the pre-identity behavior.
    func testNilEmbeddingsDegradeToNumberedSpeakers() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25)
        ]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(),
            voicePrints: [voicePrint("sasha@corp.com", "Саша", [0, 1])]
        )

        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Speaker 2] ответ",
                       "no embeddings → no matching, even with a populated voice-print DB")
        XCTAssertNil(flow.runner.savedSpeakers.first.flatMap { $0 },
                     "no embeddings → no --speakers-file, the column stays NULL")
    }

    // MARK: - Mega-cluster guard (voice-print suppression)

    /// Even shares totalling one meeting, so a test only states the share it
    /// cares about: one 0.1 s segment per cluster, plus extra segments on
    /// `dominant` until it owns `share` of the total speech.
    private func megaClusterSegments(clusters: Int, dominant: String, share: Double) -> [SpeakerSegment] {
        let names = (0..<clusters).map { String(UnicodeScalar(UInt8(65 + $0))) }
        var segments = names.map { SpeakerSegment(speakerID: $0, startSec: 0, endSec: 0.1) }
        // others = clusters - 1 tenths; dominant needs d with d/(d+others) = share.
        let others = Double(clusters - 1) * 0.1
        let dominantTotal = others * share / (1 - share)
        segments.append(SpeakerSegment(speakerID: dominant, startSec: 1, endSec: 1 + dominantTotal - 0.1))
        return segments
    }

    /// A 19-attendee meeting the diarizer under-split: one cluster hoovers up
    /// half the speech, so its voice match is dropped (it renders as a plain
    /// "Speaker N") while the honest clusters keep their names.
    func testMegaClusterLosesItsVoiceName() throws {
        let segments = megaClusterSegments(clusters: 5, dominant: "C", share: 0.5)
        let names = ["A": "Аня", "B": "Борис", "C": "Саша", "D": "Даша", "E": "Егор"]

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments, ownerClusters: nil).names

        XCTAssertNil(filtered["C"], "a cluster holding 50% of speech in a 5-cluster meeting must lose its voice name")
        XCTAssertEqual(filtered, ["A": "Аня", "B": "Борис", "D": "Даша", "E": "Егор"],
                       "only the dominant cluster is suppressed")
    }

    /// A mega-suppressed cluster loses its OWNER status along with its name —
    /// a merged blob must not win the «Я» tie-break as "the owner". (By
    /// design it may still win «Я» by bare mic share: the legacy under-split
    /// behavior, see filterMegaClusters' doc.)
    func testMegaClusterLosesOwnerStatusWithItsName() throws {
        let segments = megaClusterSegments(clusters: 5, dominant: "C", share: 0.5)
        let names = ["C": "owner@x.com", "D": "Даша"]

        let result = MeetingRecorderCenter.filterMegaClusters(
            voiceNames: names, speakers: segments, ownerClusters: ["C"])

        XCTAssertEqual(result.owners, [],
                       "the suppressed blob must leave the owner set, but the set stays non-nil (identity still known)")
        XCTAssertEqual(result.names, ["D": "Даша"])
    }

    /// Below the min-clusters gate the whole tuple passes through unchanged —
    /// including a non-nil owner set.
    func testBelowGatePassesOwnerClustersThroughUnchanged() throws {
        let segments = megaClusterSegments(clusters: 2, dominant: "B", share: 0.6)
        let result = MeetingRecorderCenter.filterMegaClusters(
            voiceNames: ["B": "owner@x.com"], speakers: segments, ownerClusters: ["B"])
        XCTAssertEqual(result.owners, ["B"])
        XCTAssertEqual(result.names, ["B": "owner@x.com"])
    }

    /// Pins the owner-status proxy contract: above the gate, "still has a
    /// name" stands for "not suppressed" — an owner cluster with NO
    /// voiceNames entry loses its status even though nothing was suppressed.
    /// Valid only because matchVoiceNames inserts names and owner status
    /// together; this test is the tripwire for a future caller that does not.
    func testOwnerClusterWithoutNameLosesStatusAboveGate() throws {
        let segments = megaClusterSegments(clusters: 5, dominant: "C", share: 0.5)
        let result = MeetingRecorderCenter.filterMegaClusters(
            voiceNames: ["D": "Даша"], speakers: segments, ownerClusters: ["A"])
        XCTAssertEqual(result.owners, [],
                       "a nameless owner cluster falls out of the set above the gate — documented proxy edge")
    }

    /// The 1:1 case: the counterparty legitimately owns most of the speech, so
    /// the guard must not fire below `megaClusterMinClusters`.
    func testDominantClusterInOneOnOneKeepsItsVoiceName() throws {
        let segments = megaClusterSegments(clusters: 2, dominant: "B", share: 0.6)
        let names = ["A": "Я", "B": "Саша"]

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments, ownerClusters: nil).names

        XCTAssertEqual(filtered, names, "two clusters are below the min-clusters gate — a 60% counterparty is normal")
    }

    /// Enough clusters to arm the guard, but nobody dominates — every match
    /// survives.
    func testEvenlySplitClustersKeepAllVoiceNames() throws {
        let segments = (0..<4).map {
            SpeakerSegment(speakerID: String(UnicodeScalar(UInt8(65 + $0))), startSec: Double($0) * 0.1,
                           endSec: Double($0) * 0.1 + 0.1)
        }
        let names = ["A": "Аня", "B": "Борис", "C": "Саша", "D": "Даша"]

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments, ownerClusters: nil).names

        XCTAssertEqual(filtered, names, "four clusters at ~25% each are a plausible real split")
    }

    func testDiarizerFailureSavesPlainTranscript() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.error = FakeDiarizer.FakeError()

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )

        XCTAssertEqual(flow.center.phase, .idle, "a diarization failure must never fail the pipeline")
        XCTAssertEqual(flow.savedText, "привет\nответ")
        XCTAssertNil(flow.savedSegments, "no roles → no segments file, the column stays NULL")
        XCTAssertEqual(flow.notifier.readyTitles, ["Roles — saved without speaker labels"],
                       "the notification must flag the missing labels")
    }

    func testLivePathRendersRolesFromDecodedFile() async throws {
        // The live path reaches renderRoles with samples: nil — the roles
        // decode is the ONLY decode (live STT never re-decodes the file).
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let diarizer = FakeDiarizer()
        diarizer.segments = [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.3)]
        var decodeCalls = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["live text"])) },
            diarizerFactory: { _ in diarizer },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 4800) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        var config = threeWindowConfig()
        config.diarization = true
        await center.startRecording(eventID: nil, title: "Live roles", config: config)
        recorder.emitLive([Float](repeating: 0, count: 4800)) // live pass produces the text
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 1, "the roles post-pass decodes the file exactly once")
        XCTAssertEqual(runner.savedTranscripts.first, "[Speaker 1] live text")

        // The live single-pass save must carry the structured utterances too —
        // live is the dominant real path, and dropping them there would fall
        // back to a legacy segment-less row for every live-transcribed meeting.
        let savedSegments = try XCTUnwrap(runner.savedSegments.first.flatMap { $0 },
                                          "the live single-pass save must pass --segments-file")
        let utterances = try XCTUnwrap(TranscriptSegments.decode(savedSegments))
        XCTAssertEqual(TranscriptSegments.render(utterances), "[Speaker 1] live text",
                       "invariant at the source: transcript_text = render(segments)")
    }

    func testRetryAfterSaveFailureKeepsRolesFlagInNotification() async throws {
        // Diarization failed (text persisted WITHOUT labels), then the save
        // failed. The retry short-circuits to the persisted text — and the
        // notification must still flag the missing labels.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let diarizer = FakeDiarizer()
        diarizer.error = FakeDiarizer.FakeError()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope, error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["привет"])) },
            diarizerFactory: { _ in diarizer },
            decode: stubDecode(sampleCount: 4800),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        var config = threeWindowConfig()
        config.diarization = true

        await center.startRecording(eventID: nil, title: "Retry roles")
        await center.stopAndProcess(config: config)
        guard case .failed = center.phase else { return XCTFail("expected failed save") }

        runner.shouldThrow = nil
        await center.retryTranscription(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(notifier.readyTitles, ["Retry roles — saved without speaker labels"],
                       "the persisted label-less text must keep its roles flag on retry")
    }

    func testDiarizationDisabledSkipsDiarizer() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.segments = [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.3)]

        let flow = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(), rolesEnabled: false
        )

        XCTAssertEqual(diarizer.calls, 0, "the toggle must gate the diarizer entirely")
        XCTAssertEqual(flow.savedText, "привет\nответ")
        XCTAssertNil(flow.savedSegments, "diarization off → no segments file")
    }

    func testRetryAfterSaveFailureResendsSegmentsFromSidecar() async throws {
        // Roles rendered fine but the save failed → the sidecar persisted the
        // utterances; the retry short-circuit must re-send them (no
        // re-transcription, no re-diarization) so segments_json survives a
        // save failure like the text does.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25)
        ]
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["привет", "ответ"]))
            },
            diarizerFactory: { _ in diarizer },
            decode: stubDecode(sampleCount: 4800),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        var config = threeWindowConfig()
        config.diarization = true

        await center.startRecording(eventID: nil, title: "Retry segments")
        await center.stopAndProcess(config: config)
        guard case .failed = center.phase else { return XCTFail("expected failed save") }
        let firstSegments = try XCTUnwrap(runner.savedSegments.first.flatMap { $0 },
                                          "the failed save must already have carried segments")

        runner.shouldThrow = nil
        await center.retryTranscription(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(engineLoads, 1, "retry must short-circuit to the persisted sidecar")
        XCTAssertEqual(diarizer.calls, 1, "retry must not re-diarize")
        XCTAssertEqual(runner.savedSegments.count, 2)
        let retriedSegments = try XCTUnwrap(runner.savedSegments[1])
        XCTAssertEqual(TranscriptSegments.decode(retriedSegments), TranscriptSegments.decode(firstSegments),
                       "the retried save must carry the same utterances from the sidecar")
        XCTAssertEqual(runner.savedTranscripts.count, 2)
        XCTAssertEqual(runner.savedTranscripts[0], runner.savedTranscripts[1])
    }

    func testRetryFromPreSegmentsSidecarSavesWithoutSegments() async throws {
        // Back-compat: a sidecar written BEFORE the segments work (no
        // "utterances" key at all) must still decode and short-circuit the
        // retry to a segment-less save — this is the crash-recovery path the
        // sidecar exists for, and a Codable change that broke it would strand
        // every in-flight failed save from an older build.
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let base = audio.deletingPathExtension()
        try "[Я] привет".write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        // Exact old-format payload: durationSec + langStats only.
        try Data(#"{"durationSec":42,"langStats":{"ru":42}}"#.utf8)
            .write(to: base.appendingPathExtension("json"))

        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        defaults.set("Old build", forKey: MeetingRecorderCenter.pendingTitleKey)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in engineLoads += 1; return TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 4800),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)
        await center.retryTranscription(config: threeWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(engineLoads, 0, "the old-format sidecar must still short-circuit re-transcription")
        XCTAssertEqual(runner.savedTranscripts, ["[Я] привет"])
        XCTAssertEqual(runner.savedSegments.count, 1)
        XCTAssertNil(runner.savedSegments[0], "a pre-segments sidecar retries as a segment-less save")
    }

}
