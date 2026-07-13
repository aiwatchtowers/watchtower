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

    func start(to url: URL) async throws {
        startCalls += 1
        lastStartURL = url
        if let startError { throw startError }
    }

    func stop() async throws -> RecordingResult {
        stopCalls += 1
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

    func transcribeWindow(_ samples: [Float], language: String) async throws -> String {
        defer { index += 1 }
        return index < texts.count ? texts[index] : ""
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

    func transcribeWindow(_ samples: [Float], language: String) async throws -> String {
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
        return index < texts.count ? texts[index] : ""
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

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MeetingRecorderCenterTests-\(UUID().uuidString)")!
    }

    /// A dummy on-disk file standing in for a finished recording. Its bytes are
    /// never decoded (the Center's decode seam is stubbed); it only has to exist
    /// so "audio preserved" assertions are meaningful.
    private func makeDummyAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    /// Fixed-length silent samples so downstream windowing is deterministic.
    private func stubDecode(sampleCount: Int) -> @Sendable (URL) throws -> [Float] {
        { _ in [Float](repeating: 0, count: sampleCount) }
    }

    private func singleWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        return config
    }

    /// 0.1 s windows, no overlap → 4800 samples is exactly 3 windows.
    private func threeWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.windowSec = 0.1
        config.overlapSec = 0
        return config
    }

    // MARK: Guards

    func testStartWhileBusyIsANoOp() async {
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            notifier: FakeNotifier(),
            defaults: isolatedDefaults()
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
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let notifier = FakeNotifier()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let defaults = isolatedDefaults()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["hello world"]) },
            decode: stubDecode(sampleCount: 1600),
            notifier: notifier,
            defaults: defaults
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
        XCTAssertNotNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))

        await center.stopAndProcess(runner: runner, config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey),
                     "the pending-audio key must be cleared once the transcript is saved")
        XCTAssertEqual(notifier.readyTitles, ["Ad hoc"])
        XCTAssertTrue(notifier.failedReasons.isEmpty)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.first, "meeting-prep")
    }

    func testStateSurvivesViewLifetime() async throws {
        // The "начал → ушёл → вернулся" contract: recording state lives in the
        // Center, so a view that observed it can be torn down mid-run and the run
        // still completes.
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["captured"]) },
            decode: stubDecode(sampleCount: 1600),
            notifier: FakeNotifier(),
            defaults: isolatedDefaults()
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
        await center.stopAndProcess(runner: FakeCLIRunner(stdout: recapOKEnvelope), config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
    }

    func testRecapErrorStillCompletes() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["some talk"]) },
            decode: stubDecode(sampleCount: 1600),
            notifier: notifier,
            defaults: isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(runner: FakeCLIRunner(stdout: recapFailedEnvelope), config: singleWindowConfig())

        // Transcript saved even though the recap failed → completes at idle with a
        // ready notification that flags the pending recap retry.
        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(notifier.readyTitles.count, 1)
        XCTAssertTrue(notifier.readyTitles.first?.localizedCaseInsensitiveContains("recap") ?? false,
                      "ready notification must mention the recap needs retry, got \(notifier.readyTitles)")
        XCTAssertTrue(notifier.failedReasons.isEmpty)
    }

    // MARK: Failure paths

    func testRecorderStartFailureGoesFailed() async {
        let recorder = FakeRecorder()
        recorder.startError = AudioRecordingError.microphonePermissionDenied
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            notifier: notifier,
            defaults: isolatedDefaults()
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly")

        guard case .failed = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
        XCTAssertFalse(center.isBusy, "a failed start must not leave the Center stuck busy")
        XCTAssertEqual(notifier.failedReasons.count, 1)
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
            notifier: notifier,
            defaults: isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(runner: runner, config: singleWindowConfig())

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
        defer { try? FileManager.default.removeItem(at: audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 5)
        let notifier = FakeNotifier()
        let defaults = isolatedDefaults()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["real speech"]) },
            decode: stubDecode(sampleCount: 1600),
            notifier: notifier,
            defaults: defaults
        )

        let failingRunner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked"))
        await center.startRecording(eventID: nil, title: "Ad hoc")
        await center.stopAndProcess(runner: failingRunner, config: singleWindowConfig())

        guard case .failed = center.phase else {
            return XCTFail("expected .failed after save error, got \(center.phase)")
        }
        XCTAssertEqual(center.pendingAudioURL, audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))

        // Retry with a working runner re-enters at decode and finishes clean.
        let goodRunner = FakeCLIRunner(stdout: recapOKEnvelope)
        await center.retryTranscription(runner: goodRunner, config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
        XCTAssertNil(defaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
        XCTAssertEqual(goodRunner.invocations.count, 1)
    }

    // MARK: Recovery / launch

    func testRestorePendingOnLaunch() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let defaults = isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            notifier: FakeNotifier(),
            defaults: defaults
        )

        center.restorePendingOnLaunch()
        XCTAssertEqual(center.pendingAudioURL, audio)

        // Missing file → the stale key is cleared.
        let missingDefaults = isolatedDefaults()
        missingDefaults.set("/tmp/does-not-exist-\(UUID().uuidString).m4a", forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center2 = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in ScriptedEngine(texts: []) },
            decode: stubDecode(sampleCount: 1600),
            notifier: FakeNotifier(),
            defaults: missingDefaults
        )
        center2.restorePendingOnLaunch()
        XCTAssertNil(center2.pendingAudioURL)
        XCTAssertNil(missingDefaults.string(forKey: MeetingRecorderCenter.pendingAudioPathKey))
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
        defer { try? FileManager.default.removeItem(at: audio) }

        let engine = GateEngine(texts: ["a", "b", "c"])
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in engine },
            decode: stubDecode(sampleCount: 4800), // 3 windows at 0.1 s / no overlap
            notifier: FakeNotifier(),
            defaults: isolatedDefaults()
        )

        center.prepareRetry(audioURL: audio, eventID: nil, title: "Ad hoc")
        let runTask = Task {
            await center.retryTranscription(runner: FakeCLIRunner(stdout: recapOKEnvelope), config: threeWindowConfig())
        }

        var entered = engine.enteredStream.makeAsyncIterator()

        // At each window entry, only the previous windows' progress has been
        // reported: window 1 → initial 0/0, window 2 → 1/3, window 3 → 2/3.
        let expected: [MeetingRecorderCenter.Phase] = [
            .transcribing(done: 0, total: 0),
            .transcribing(done: 1, total: 3),
            .transcribing(done: 2, total: 3),
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
}
