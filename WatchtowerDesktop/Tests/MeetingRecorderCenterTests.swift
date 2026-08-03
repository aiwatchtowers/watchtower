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
private final class ScriptedEngine: WhisperWindowEngine, @unchecked Sendable {
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
private final class GateEngine: WhisperWindowEngine, @unchecked Sendable {
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

/// Adapts a `WhisperWindowEngine` test double (`ScriptedEngine`/`GateEngine`) to
/// the pluggable `Transcriber` contract, mirroring production's
/// `WhisperTranscriber`/`WhisperLiveSession` shape (`Providers/WhisperKitProvider.swift`)
/// so the existing engine fakes keep driving the real `WindowedTranscriber`/
/// `StreamingTranscriber` algorithms unchanged after `MeetingRecorderCenter`'s
/// `engineFactory` moved from `WhisperWindowEngine` to `Transcriber`.
private final class TestTranscriber: Transcriber, @unchecked Sendable {
    let engine: WhisperWindowEngine
    let supportsLive: Bool

    init(_ engine: WhisperWindowEngine, supportsLive: Bool = true) {
        self.engine = engine
        self.supportsLive = supportsLive
    }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        try await WindowedTranscriber(engine: engine, config: config).transcribe(samples: samples, progress: progress)
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        guard supportsLive else { return nil }
        return TestLiveSession(engine: engine, config: config)
    }
}

private struct TestLiveSession: TranscriptionLiveSession {
    let engine: WhisperWindowEngine
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        try await StreamingTranscriber(engine: engine, config: config).run(samples: samples, onChunk: onChunk)
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

/// Reads the files passed via --transcript-file / --segments-file /
/// --speakers-file DURING the CLI invocation (the save service deletes them
/// right after), capturing the exact saved text, segments JSON and speakers
/// JSON (nil when the corresponding file was not passed).
/// `shouldThrow` (cleared by the test for a retry) fails the save AFTER
/// capturing, mirroring FakeCLIRunner's failure knob.
private final class TranscriptCapturingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let stdoutData: Data
    var shouldThrow: Error?
    private(set) var savedTranscripts: [String] = []
    private(set) var savedSegments: [String?] = []
    private(set) var savedSpeakers: [String?] = []

    init(stdout: Data) { self.stdoutData = stdout }

    func run(args: [String]) async throws -> Data {
        if let idx = args.firstIndex(of: "--transcript-file"), idx + 1 < args.count,
           let text = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            savedTranscripts.append(text)
        }
        if let idx = args.firstIndex(of: "--segments-file"), idx + 1 < args.count,
           let json = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            savedSegments.append(json)
        } else {
            savedSegments.append(nil)
        }
        if let idx = args.firstIndex(of: "--speakers-file"), idx + 1 < args.count,
           let json = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            savedSpeakers.append(json)
        } else {
            savedSpeakers.append(nil)
        }
        if let shouldThrow { throw shouldThrow }
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

    /// Stand-in for the user's real recordings directory: the Center writes
    /// `rec_*.caf`/`rec_*.meta` here and scans it on launch, so a test must
    /// neither litter nor read the real one (a leftover recording there would
    /// surface as a recovered one and change what the assertions see).
    private var recordingsDir: URL!

    override func setUp() {
        super.setUp()
        recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: recordingsDir)
        super.tearDown()
    }

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
    /// (`<basename>.txt`/`.json`), the mic-activity timeline (`.activity`) and
    /// the crash-recovery metadata (`.meta`).
    private func removeSidecars(_ audio: URL) {
        for ext in ["txt", "json", "activity", "meta"] {
            try? FileManager.default.removeItem(at: audio.deletingPathExtension().appendingPathExtension(ext))
        }
    }

    /// The crash-recovery sidecar the Center writes next to a recording at start
    /// and removes once the transcript is saved.
    private func metaSidecar(_ audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("meta")
    }

    /// The one recording the Center started this test (its `.caf` in the
    /// injected recordings directory). The fake recorder never writes audio, so
    /// only the `.meta` sidecar the Center itself wrote is on disk.
    private func startedRecordingMeta() throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
        return recordingsDir.appendingPathComponent(
            try XCTUnwrap(names.first { $0.hasSuffix(".meta") },
                          "the Center must write a rec_*.meta sidecar at record start"))
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
    }

    /// Batch-path harness: recording → (empty live) → decode stub → scripted
    /// engine → fake diarizer → capturing runner.
    private func runDiarizationFlow(
        audio: URL,
        diarizer: FakeDiarizer,
        defaults: UserDefaults,
        rolesEnabled: Bool = true,
        voicePrints: [VoicePrint] = []
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
        // empty array behaves exactly like no voice-print database.
        center.voicePrintsLoader = { voicePrints }
        var config = threeWindowConfig()
        config.diarization = rolesEnabled
        await center.startRecording(eventID: nil, title: "Roles")
        await center.stopAndProcess(config: config)
        return DiarizationFlowResult(savedText: runner.savedTranscripts.first,
                                     savedSegments: runner.savedSegments.first.flatMap { $0 },
                                     center: center, notifier: notifier, runner: runner)
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

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments)

        XCTAssertNil(filtered["C"], "a cluster holding 50% of speech in a 5-cluster meeting must lose its voice name")
        XCTAssertEqual(filtered, ["A": "Аня", "B": "Борис", "D": "Даша", "E": "Егор"],
                       "only the dominant cluster is suppressed")
    }

    /// The 1:1 case: the counterparty legitimately owns most of the speech, so
    /// the guard must not fire below `megaClusterMinClusters`.
    func testDominantClusterInOneOnOneKeepsItsVoiceName() throws {
        let segments = megaClusterSegments(clusters: 2, dominant: "B", share: 0.6)
        let names = ["A": "Я", "B": "Саша"]

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments)

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

        let filtered = MeetingRecorderCenter.filterMegaClusters(voiceNames: names, speakers: segments)

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

    // MARK: - Processing queue (capture decoupled from post-processing)

    /// The back-to-back-meetings case: the next meeting starts capturing while
    /// the previous recording is still being transcribed. Its live pass waits
    /// for the engine slot the running job holds — one engine, ever — and loads
    /// only once that job is done.
    func testRecordingStartsWhileJobTranscribesAndLivePassWaitsForTheSlot() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        let gate = GateEngine(texts: ["job one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["job two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        // Job 1 is now parked inside the gated engine.
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        XCTAssertEqual(engineLoads, 1, "the live pass's engine is handed to the batch fallback, not reloaded")

        await center.startRecording(eventID: "evt-2", title: "Second", config: config)

        guard case .recording = center.captureState else {
            return XCTFail("a new recording must start while a job is transcribing, got \(center.captureState)")
        }
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the live pass must wait for the engine slot the running job holds")
        XCTAssertEqual(engineLoads, 1, "no second engine may load while the job owns the slot")
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs.first?.phase, .transcribing(done: 0, total: 0),
                       "the running job is untouched by the new recording")

        gate.release()
        await stopFirst.value
        XCTAssertTrue(center.jobs.isEmpty, "job 1 saved and left the queue")
        XCTAssertEqual(runner.invocations.count, 1)

        // The waiting live pass gets the slot now — and only now.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(engineLoads, 2, "the waiting live pass loads its engine after the job finished")
        XCTAssertNotEqual(center.liveEngineState, .waiting)

        // Hygiene: drive recording 2 to completion so no task is left dangling.
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(center.phase, .idle)
    }

    /// Two stopped recordings queue FIFO behind one another and both save, in
    /// the order they were stopped — the queue is serial, never concurrent.
    func testSecondStopQueuesBehindTheRunningJobAndBothSave() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        let gate = GateEngine(texts: ["job one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["job two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()

        await center.startRecording(eventID: nil, title: "Second", config: config)
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<12 { await Task.yield() }

        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1, audio2], "the queue is FIFO")
        XCTAssertEqual(center.jobs.last?.phase, .queued,
                       "the second job waits — exactly one job processes at a time")

        gate.release()
        await stopFirst.value
        await stopSecond.value

        XCTAssertEqual(runner.savedTranscripts, ["job one", "job two"],
                       "both recordings save, in the order they were stopped")
        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertEqual(center.phase, .idle)
    }

    /// A failed job stays in the queue for retry without blocking anything: the
    /// job behind it still runs, a new recording still starts, and retrying
    /// re-enqueues the failed one.
    func testFailedJobBlocksNeitherTheQueueNorNewRecordings() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        var recorderCalls = 0
        var engineLoads = 0
        // Recording 1's decode fails once, so its job lands `.failed` with the
        // audio kept; the retry below decodes fine.
        var failFirstDecode = true
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: [engineLoads == 2 ? "job two" : "job one"]))
            },
            decode: { url in
                if url == audio1, failFirstDecode { throw AudioFileDecoderError.unsupportedFormat }
                return [Float](repeating: 0, count: 1600)
            },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)
        XCTAssertEqual(center.pendingAudioURL, audio1, "the audio must be kept for retry")
        XCTAssertFalse(center.isCapturing, "a failed job must never gate the next recording")

        // A whole second recording runs to completion past the failed job.
        await center.startRecording(eventID: nil, title: "Second", config: config)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(runner.savedTranscripts, ["job two"],
                       "the queue advanced past the failure")
        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1],
                       "only the failed job is left, still visible for retry")

        // Retry re-enqueues the SAME job.
        failFirstDecode = false
        await center.retryTranscription(config: config)

        XCTAssertEqual(runner.savedTranscripts, ["job two", "job one"])
        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
    }

    /// The tightest window the decoupling opens: recording 2 is started AND
    /// stopped while recording 1's live pass is still draining its tail. The
    /// second recording never had a live pass of its own, so it must not consume
    /// the first one's output (or its engine) — it goes through the batch path,
    /// and the live text lands on the recording that produced it.
    func testRecordingStoppedWhileWaitingNeverConsumesThePriorLiveTail() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        // Gating the LIVE engine parks recording 1's tail mid-window.
        let gate = GateEngine(texts: ["live one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["batch two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig() // 0.1 s windows → 1600 samples per window

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.emitLive([Float](repeating: 0, count: 1600)) // exactly one window
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // recording 1's live pass is parked in the engine
        for _ in 0..<12 { await Task.yield() }

        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the draining tail still owns the engine slot")
        XCTAssertEqual(engineLoads, 1)

        let stopSecond = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1, audio2], "queue order is stop order")

        gate.release()
        await stopFirst.value
        await stopSecond.value

        XCTAssertEqual(runner.savedTranscripts, ["live one", "batch two"],
                       "the live text belongs to the recording that produced it; "
                       + "the second recording is transcribed from its own file")
        XCTAssertEqual(engineLoads, 2, "the second recording's job loads its own engine")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    // MARK: - Crash-recovery sidecars

    /// `rec_X.meta` is the per-recording replacement for the single-slot
    /// `UserDefaults` pointer: written before capture starts, removed once the
    /// transcript is saved (so "sidecar present" == "never saved").
    func testMetaSidecarWrittenAtStartAndRemovedAfterSave() async throws {
        let recorder = FakeRecorder()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly", config: singleWindowConfig())

        let started = try XCTUnwrap(recorder.lastStartURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaSidecar(started).path),
                      "the recovery sidecar must exist from record start, before any audio is finalized")

        // Production's recorder finalizes the very file it was started on.
        recorder.stopResult = RecordingResult(audioURL: started, durationSec: 1)
        defer { removeSidecars(started) }
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaSidecar(started).path),
                       "a saved transcript must remove the recovery sidecar")
    }

    /// Recovery generalizes to N recordings: every `rec_*.caf` that still has a
    /// `.meta` sidecar comes back (oldest first, event link intact), while one
    /// whose sidecar is gone — i.e. already saved — is left alone.
    func testRecoveryScanFindsEveryOrphanedRecording() async throws {
        let older = recordingsDir.appendingPathComponent("rec_20260803_100000.caf")
        let newer = recordingsDir.appendingPathComponent("rec_20260803_120000.caf")
        let saved = recordingsDir.appendingPathComponent("rec_20260803_110000.caf")
        for audio in [older, newer, saved] {
            try Data([0x00]).write(to: audio)
        }
        try #"{"eventID":"evt-older","title":"Older"}"#
            .write(to: metaSidecar(older), atomically: true, encoding: .utf8)
        try #"{"title":"Newer ad-hoc"}"#
            .write(to: metaSidecar(newer), atomically: true, encoding: .utf8)

        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.map(\.audioURL), [older, newer],
                       "every unsaved recording is recovered, oldest first; a sidecar-less one is not")
        XCTAssertEqual(center.recoverable.map(\.eventID), ["evt-older", nil])
        XCTAssertEqual(center.recoverable.map(\.title), ["Older", "Newer ad-hoc"])
        // The legacy pill acts on the oldest, so its event link is the current one.
        XCTAssertEqual(center.currentEventID, "evt-older")
        XCTAssertEqual(center.pendingAudioURL, older)
    }

    /// A recording captured by a pre-queue build lives in three `UserDefaults`
    /// keys. They are read once, converted to a recoverable recording, and
    /// cleared — so a second launch neither re-reads nor duplicates them.
    func testLegacyPendingDefaultsMigrateOnceAndAreCleared() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        defaults.set("evt-legacy", forKey: MeetingRecorderCenter.pendingEventIDKey)
        defaults.set("Legacy build", forKey: MeetingRecorderCenter.pendingTitleKey)
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

        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio])
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-legacy")
        XCTAssertEqual(center.recoverable.first?.title, "Legacy build")
        for key in [MeetingRecorderCenter.pendingAudioPathKey,
                    MeetingRecorderCenter.pendingEventIDKey,
                    MeetingRecorderCenter.pendingTitleKey] {
            XCTAssertNil(defaults.string(forKey: key), "\(key) must be cleared by the one-shot migration")
        }

        // A second launch of the same Center must not re-add or duplicate it.
        center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio])
    }
}
