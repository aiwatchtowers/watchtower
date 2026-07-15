import Foundation
import XCTest
@testable import WatchtowerDesktop

// MARK: - Fakes

/// Scriptable `AudioRecording`. `start` never writes real audio; `stop` returns a
/// caller-supplied `RecordingResult`. The Center's decode step is a seam the test
/// stubs, so the returned `audioURL` need only exist on disk (a dummy byte file)
/// where a test asserts the audio is preserved.
private final class FakeRecorder: AudioRecording, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    var stopResult: RecordingResult?

    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var lastStartURL: URL?

    // Live-sample plumbing: a test can push samples then finish, or leave it to
    // finish on stop() (the default: empty stream → live pass yields nothing).
    private var liveContinuation: AsyncStream<[Float]>.Continuation!
    let liveSamples: AsyncStream<[Float]>

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { c = $0 }
        liveContinuation = c
    }

    /// Emit one live piece (test drives the live path with this).
    func emitLive(_ samples: [Float]) { liveContinuation.yield(samples) }

    func start(to url: URL) async throws {
        startCalls += 1
        lastStartURL = url
        if let startError { throw startError }
    }

    func stop() async throws -> RecordingResult {
        stopCalls += 1
        liveContinuation.finish()
        if let stopError { throw stopError }
        guard let stopResult else {
            throw AudioRecordingError.deviceSetupFailed("FakeRecorder has no stopResult")
        }
        return stopResult
    }
}

/// Returns canned window texts in order; `""` past the end (silence). Used with a
/// forced-language config so `detectLanguage` is never consulted.
private final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let texts: [String]
    private var index = 0

    init(texts: [String]) { self.texts = texts }

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 1.0] }

    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment] {
        defer { index += 1 }
        let text = index < texts.count ? texts[index] : ""
        return [TranscribedSegment(text: text, startSec: 0,
                                   endSec: Double(samples.count) / Double(TranscriptionConfig.sampleRate))]
    }
}

/// Blocks on every `transcribeWindow` until the test releases it, and signals
/// entry via `enteredStream`. This lock-steps the windowed loop with the test so
/// progress delivery into `phase` can be asserted deterministically (no race
/// between the off-main transcription and the main-actor progress consumer).
private final class GateEngine: TranscriptionEngine, @unchecked Sendable {
    let texts: [String]
    let enteredStream: AsyncStream<Void>

    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseQueued = false
    private var index = 0

    init(texts: [String]) {
        self.texts = texts
        (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    }

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 1.0] }

    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment] {
        enteredContinuation.yield(())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if releaseQueued {
                releaseQueued = false
                lock.unlock()
                continuation.resume()
            } else {
                releaseContinuation = continuation
                lock.unlock()
            }
        }
        defer { index += 1 }
        let text = index < texts.count ? texts[index] : ""
        return [TranscribedSegment(text: text, startSec: 0,
                                   endSec: Double(samples.count) / Double(TranscriptionConfig.sampleRate))]
    }

    /// Lets the currently-blocked (or next) `transcribeWindow` return.
    func release() {
        lock.lock()
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            lock.unlock()
            continuation.resume()
        } else {
            releaseQueued = true
            lock.unlock()
        }
    }
}

/// Scriptable `SpeakerDiarizing`: canned segments or a thrown error, plus a
/// call counter so tests can assert the diarizer was (not) consulted.
private final class FakeDiarizer: SpeakerDiarizing, @unchecked Sendable {
    var segments: [SpeakerSegment] = []
    var error: Error?
    private(set) var calls = 0

    struct FakeError: Error {}

    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        calls += 1
        if let error { throw error }
        return segments
    }
}

/// Reads the file passed via --transcript-file DURING the CLI invocation (the
/// save service deletes it right after), capturing the exact saved text.
private final class TranscriptCapturingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let stdoutData: Data
    private(set) var savedTranscripts: [String] = []

    init(stdout: Data) { self.stdoutData = stdout }

    func run(args: [String]) async throws -> Data {
        if let idx = args.firstIndex(of: "--transcript-file"), idx + 1 < args.count,
           let text = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            savedTranscripts.append(text)
        }
        return stdoutData
    }
}

private final class FakeNotifier: MeetingTranscriptNotifying, @unchecked Sendable {
    private(set) var readyTitles: [String] = []
    private(set) var failedReasons: [String] = []

    func sendTranscriptReadyNotification(title: String) { readyTitles.append(title) }
    func sendTranscriptFailedNotification(reason: String) { failedReasons.append(reason) }
}

// MARK: - Tests

@MainActor
final class MeetingRecorderCenterTests: XCTestCase {

    // Envelopes matching the `meeting-prep transcript save` CLI contract.
    private let recapOKEnvelope = Data(#"{"transcript_id":7,"recap_ok":true,"recap_error":""}"#.utf8)
    private let recapFailedEnvelope = Data(#"{"transcript_id":7,"recap_ok":false,"recap_error":"AI generation: boom"}"#.utf8)

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "MeetingRecorderCenterTests-\(UUID().uuidString)"))
    }

    /// A dummy on-disk file standing in for a finished recording. Its bytes are
    /// never decoded (the Center's decode seam is stubbed); it only has to exist
    /// so "audio preserved" assertions are meaningful.
    private func makeDummyAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).caf")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    /// Fixed-length silent samples so downstream windowing is deterministic.
    private func stubDecode(sampleCount: Int) -> @Sendable (URL) throws -> [Float] {
        { _ in [Float](repeating: 0, count: sampleCount) }
    }

    /// Removes the recording's sidecars: the persisted transcript
    /// (`<basename>.txt`/`.json`) and the mic-activity timeline (`.activity`).
    private func removeSidecars(_ audio: URL) {
        for ext in ["txt", "json", "activity"] {
            try? FileManager.default.removeItem(at: audio.deletingPathExtension().appendingPathExtension(ext))
        }
    }

    /// Diarization is off in the shared configs: a test whose output has
    /// segments would otherwise hit the REAL FluidAudioDiarizer.load()
    /// (network + CoreML) through the default factory. The diarization tests
    /// opt back in via runDiarizationFlow with a FakeDiarizer.
    private func singleWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.diarization = false
        return config
    }

    /// 0.1 s windows, no overlap → 4800 samples is exactly 3 windows.
    private func threeWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.windowSec = 0.1
        config.overlapSec = 0
        config.boundarySnapSec = 0 // exact 3-window layout is asserted
        config.diarization = false // see singleWindowConfig
        return config
    }

    // MARK: Guards

    func testStartWhileBusyIsANoOp() async throws {
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["hello world"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
        XCTAssertNotNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))

        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey),
                     "the pending-audio key must be cleared once the transcript is saved")
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
            engineFactory: { _ in ScriptedEngine(texts: ["captured"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["some talk"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapFailedEnvelope) },
            notifier: notifier,
            defaults: try isolatedDefaults()
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

    // MARK: Failure paths

    func testRecorderStartFailureGoesFailed() async throws {
        let recorder = FakeRecorder()
        recorder.startError = AudioRecordingError.microphonePermissionDenied
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["hello"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults
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
        XCTAssertNotNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
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
                return ScriptedEngine(texts: ["hello"])
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["hello"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["hello"]) },
            decode: { _ in throw AudioFileDecoderError.unsupportedFormat },
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: ["real speech"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in ScriptedEngine(texts: []) }, // all-silence
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults()
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
                return ScriptedEngine(texts: ["real speech"])
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { activeRunner },
            notifier: notifier,
            defaults: defaults
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
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
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
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: defaults
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)

        // Missing file → the stale key is cleared.
        let missingDefaults = try isolatedDefaults()
        missingDefaults.set("/tmp/does-not-exist-\(UUID().uuidString).caf", forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center2 = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: missingDefaults
        )
        center2.restorePendingOnLaunch()
        XCTAssertNil(center2.pendingAudioURL)
        XCTAssertNil(missingDefaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
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
            engineFactory: { _ in ScriptedEngine(texts: ["recovered speech"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)
        XCTAssertEqual(center.currentEventID, "evt-42", "the event link must survive relaunch")
        XCTAssertEqual(center.currentTitle, "Weekly sync", "the title must survive relaunch")

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
                return ScriptedEngine(texts: ["fresh transcription"])
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
                return ScriptedEngine(texts: ["fresh"])
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults
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
            engineFactory: { _ in engine },
            decode: stubDecode(sampleCount: 4800), // 3 windows at 0.1 s / no overlap
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
            engineFactory: { _ in engineLoads += 1; return ScriptedEngine(texts: ["live one", "live two"]) },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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

    func testLiveChunksAccumulateAndSurviveViewLifetime() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["alpha", "beta"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
                return ScriptedEngine(texts: ["batch recovered"])  // stop-time fallback succeeds
            },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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
                return engineFactoryCalls == 1 ? gateEngine : secondEngine
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
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

    /// Batch-path harness: recording → (empty live) → decode stub → scripted
    /// engine → fake diarizer → capturing runner. Returns the saved text.
    private func runDiarizationFlow(
        audio: URL,
        diarizer: FakeDiarizer,
        defaults: UserDefaults,
        rolesEnabled: Bool = true
    ) async throws -> (savedText: String?, center: MeetingRecorderCenter, notifier: FakeNotifier) {
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["привет", "ответ"]) },
            diarizerFactory: { diarizer },
            decode: stubDecode(sampleCount: 4800), // 3 windows of 0.1 s
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults
        )
        var config = threeWindowConfig()
        config.diarization = rolesEnabled
        await center.startRecording(eventID: nil, title: "Roles")
        await center.stopAndProcess(config: config)
        return (runner.savedTranscripts.first, center, notifier)
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

        let (saved, center, notifier) = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(saved, "[Speaker 1] привет\n[Speaker 2] ответ")
        XCTAssertEqual(notifier.readyTitles, ["Roles"], "successful roles must not flag the notification")
        XCTAssertEqual(diarizer.calls, 1)
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

        let (saved, _, _) = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )

        XCTAssertEqual(saved, "[Я] привет\n[Speaker 1] ответ")
    }

    func testDiarizerFailureSavesPlainTranscript() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let diarizer = FakeDiarizer()
        diarizer.error = FakeDiarizer.FakeError()

        let (saved, center, notifier) = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults()
        )

        XCTAssertEqual(center.phase, .idle, "a diarization failure must never fail the pipeline")
        XCTAssertEqual(saved, "привет\nответ")
        XCTAssertEqual(notifier.readyTitles, ["Roles — saved without speaker labels"],
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
            engineFactory: { _ in ScriptedEngine(texts: ["live text"]) },
            diarizerFactory: { diarizer },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 4800) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
        )

        var config = threeWindowConfig()
        config.diarization = true
        await center.startRecording(eventID: nil, title: "Live roles", config: config)
        recorder.emitLive([Float](repeating: 0, count: 4800)) // live pass produces the text
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 1, "the roles post-pass decodes the file exactly once")
        XCTAssertEqual(runner.savedTranscripts.first, "[Speaker 1] live text")
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
            engineFactory: { _ in ScriptedEngine(texts: ["привет"]) },
            diarizerFactory: { diarizer },
            decode: stubDecode(sampleCount: 4800),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults()
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

        let (saved, _, _) = try await runDiarizationFlow(
            audio: audio, diarizer: diarizer, defaults: try isolatedDefaults(), rolesEnabled: false
        )

        XCTAssertEqual(diarizer.calls, 0, "the toggle must gate the diarizer entirely")
        XCTAssertEqual(saved, "привет\nответ")
    }
}
