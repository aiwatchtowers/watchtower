import Foundation
import XCTest
@testable import WatchtowerDesktop

// MARK: - Fakes

/// Scriptable `AudioRecording`. `start` never writes real audio; `stop` returns a
/// caller-supplied `RecordingResult`. The Center's decode step is a seam the test
/// stubs, so the returned `audioURL` need only exist on disk (a dummy byte file)
/// where a test asserts the audio is preserved.
final class FakeRecorder: AudioRecording, @unchecked Sendable {
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
final class ScriptedEngine: WhisperWindowEngine, @unchecked Sendable {
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
final class GateEngine: WhisperWindowEngine, @unchecked Sendable {
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
final class TestTranscriber: Transcriber, @unchecked Sendable {
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

struct TestLiveSession: TranscriptionLiveSession {
    let engine: WhisperWindowEngine
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        try await StreamingTranscriber(engine: engine, config: config).run(samples: samples, onChunk: onChunk)
    }
}

/// Scriptable `SpeakerDiarizing`: canned segments or a thrown error, plus a
/// call counter so tests can assert the diarizer was (not) consulted.
final class FakeDiarizer: SpeakerDiarizing, @unchecked Sendable {
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
final class TranscriptCapturingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let stdoutData: Data
    var shouldThrow: Error?
    private(set) var invocations: [[String]] = []
    private(set) var savedTranscripts: [String] = []
    private(set) var savedSegments: [String?] = []
    private(set) var savedSpeakers: [String?] = []

    init(stdout: Data) { self.stdoutData = stdout }

    func run(args: [String]) async throws -> Data {
        invocations.append(args)
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

final class FakeNotifier: MeetingTranscriptNotifying, @unchecked Sendable {
    private(set) var readyTitles: [String] = []
    private(set) var failedReasons: [String] = []

    func sendTranscriptReadyNotification(title: String) { readyTitles.append(title) }
    func sendTranscriptFailedNotification(reason: String) { failedReasons.append(reason) }
}

// MARK: - Shared fixtures

/// Shared fixtures for the recorder-center test suites: an isolated
/// recordings directory per test plus the dummy-audio/config/sidecar
/// helpers both `MeetingRecorderCenterTests` and
/// `MeetingRecorderQueueTests` drive the Center with.
@MainActor
class MeetingRecorderTestCase: XCTestCase {

    /// Stand-in for the user's real recordings directory: the Center writes
    /// `rec_*.caf`/`rec_*.meta` here and scans it on launch, so a test must
    /// neither litter nor read the real one (a leftover recording there would
    /// surface as a recovered one and change what the assertions see).
    var recordingsDir: URL!

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
    let recapOKEnvelope = Data(#"{"transcript_id":7,"recap_ok":true,"recap_error":""}"#.utf8)
    let recapFailedEnvelope = Data(#"{"transcript_id":7,"recap_ok":false,"recap_error":"AI generation: boom"}"#.utf8)
    let recapSkippedEnvelope = Data(
        #"{"transcript_id":7,"recap_ok":false,"recap_error":"transcript too short (12 chars): recap skipped","recap_skipped":true}"#.utf8)

    func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "MeetingRecorderCenterTests-\(UUID().uuidString)"))
    }

    /// A dummy on-disk file standing in for a finished recording. Its bytes are
    /// never decoded (the Center's decode seam is stubbed); it only has to exist
    /// so "audio preserved" assertions are meaningful.
    func makeDummyAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).caf")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    /// Fixed-length silent samples so downstream windowing is deterministic.
    func stubDecode(sampleCount: Int) -> @Sendable (URL) throws -> [Float] {
        { _ in [Float](repeating: 0, count: sampleCount) }
    }

    /// Removes the recording's sidecars: the persisted transcript
    /// (`<basename>.txt`/`.json`), the mic-activity timeline (`.activity`) and
    /// the crash-recovery metadata (`.meta`).
    func removeSidecars(_ audio: URL) {
        for ext in ["txt", "json", "activity", "meta"] {
            try? FileManager.default.removeItem(at: audio.deletingPathExtension().appendingPathExtension(ext))
        }
    }

    /// The crash-recovery sidecar the Center writes next to a recording at start
    /// and removes once the transcript is saved.
    func metaSidecar(_ audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("meta")
    }

    /// The value of `flag` in one `meeting-prep transcript save` invocation, or
    /// nil when the flag was not passed at all (an ad-hoc save omits
    /// `--event-id` entirely rather than passing an empty string).
    func savedFlag(_ invocation: [String], _ flag: String) -> String? {
        guard let idx = invocation.firstIndex(of: flag), idx + 1 < invocation.count else { return nil }
        return invocation[idx + 1]
    }

    /// The one recording the Center started this test (its `.caf` in the
    /// injected recordings directory). The fake recorder never writes audio, so
    /// only the `.meta` sidecar the Center itself wrote is on disk.
    func startedRecordingMeta() throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
        return recordingsDir.appendingPathComponent(
            try XCTUnwrap(names.first { $0.hasSuffix(".meta") },
                          "the Center must write a rec_*.meta sidecar at record start"))
    }

    /// Yields the main actor until `condition` holds. Bounded, so a regression
    /// that parks the queue forever fails an assertion instead of hanging the
    /// suite — callers must not `await` a Task that only completes on success
    /// unless this returned true.
    @discardableResult
    func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
        return false
    }

    /// Diarization is off in the shared configs: a test whose output has
    /// segments would otherwise hit the REAL FluidAudioDiarizer.load()
    /// (network + CoreML) through the default factory. The diarization tests
    /// opt back in via runDiarizationFlow with a FakeDiarizer.
    func singleWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.diarization = false
        return config
    }

    /// 0.1 s windows, no overlap → 4800 samples is exactly 3 windows.
    func threeWindowConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.windowSec = 0.1
        config.overlapSec = 0
        config.boundarySnapSec = 0 // exact 3-window layout is asserted
        config.diarization = false // see singleWindowConfig
        return config
    }

}
