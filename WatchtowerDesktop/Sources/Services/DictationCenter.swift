import SwiftUI

/// State machine driving one voice dictation: mic capture → live (or batch)
/// transcription → `DictationCleanService` cleanup → the caller's callbacks.
enum DictationPhase: Equatable {
    case idle, loadingEngine, recording, cleaning
    case failed(String)
}

/// App-wide, single-slot registry for voice dictation — the `MeetingRecorderCenter`
/// precedent, minus the post-processing queue: only one dictation can ever be
/// in flight, so there is no FIFO to manage. State lives here (never
/// view-local) so a dictation survives navigating away from the sheet/field
/// that started it.
///
/// The engine is sticky: a loaded `Transcriber` is retained for
/// `engineIdleTTL` after the dictation that loaded it finishes, so a burst of
/// quick dictations reuses one warm engine instead of paying the load cost
/// each time. `MeetingRecorderCenter` shares the same physical engine slot on
/// the machine, so it announces an upcoming capture via `captureWillStart` —
/// `meetingCaptureWillStart()` is this center's side of that handshake.
@MainActor
@Observable
final class DictationCenter {
    private(set) var phase: DictationPhase = .idle
    private(set) var activeTargetID: String?
    /// Accumulated raw text delivered so far, chunk by chunk, while live.
    private(set) var liveText: String = ""
    /// The raw transcript of the most recently finished (or failed) dictation,
    /// surviving cleanup so a failed cleanup — or a user who prefers the
    /// original wording — can fall back to it.
    private(set) var lastRaw: String?
    /// Wired by AppState to MeetingRecorderCenter.isBusy. The button reads it
    /// to disable itself; start() reads it as the belt-and-braces guard.
    var meetingBusy: () -> Bool = { false }
    /// Wired by AppState to `MeetingRecorderCenter.dictationEngineDidRelease()`:
    /// fired whenever the resident engine is dropped, so a meeting live pass
    /// parked on `hasResidentEngine` can load its engine and catch up.
    var engineReleased: (() -> Void)?

    private let recorderFactory: () -> MicRecording
    private let engineFactory: (TranscriptionConfig) async throws -> Transcriber
    private let runnerResolver: () -> CLIRunnerProtocol?
    private let defaults: UserDefaults
    private let engineIdleTTL: Duration

    private var recorder: MicRecording?
    private var dictationTask: Task<Void, Never>?
    /// The resident engine, retained across dictations until `engineReleaseTask`
    /// fires or `meetingCaptureWillStart()` claims the slot.
    private var warmTranscriber: Transcriber?
    /// The Settings provider/model pair `warmTranscriber` was loaded under —
    /// a dictation started after the owner switched either must not reuse a
    /// stale engine.
    private var warmEngineKey: String?
    private var engineReleaseTask: Task<Void, Never>?
    /// Set by `meetingCaptureWillStart()` while a dictation (or its engine
    /// load / cleanup) is still in flight: the completion path drops the
    /// resident engine outright instead of arming the idle-release timer.
    private var dropEngineAfterCleanup = false

    init(recorderFactory: @escaping () -> MicRecording = { MicRecorder() },
         engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber
             = MeetingRecorderCenter.defaultEngineFactory,
         runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
         defaults: UserDefaults = .standard,
         engineIdleTTL: Duration = .seconds(15 * 60)) {
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.runnerResolver = runnerResolver
        self.defaults = defaults
        self.engineIdleTTL = engineIdleTTL
    }

    // MARK: - Controls

    /// Starts dictating into one target. onLiveText delivers the full raw text
    /// accumulated so far; onResult delivers the cleaned result exactly once;
    /// onCleanupFailure (optional) delivers the raw transcript when the
    /// cleanup CLI failed, so the surface can keep the spoken words in the
    /// field instead of losing them. No-op while another dictation is active
    /// or the meeting recorder owns the engine slot — the button is disabled
    /// in both cases anyway, this is the belt-and-braces path.
    func start(
        targetID: String,
        mode: DictationMode,
        onLiveText: @escaping @MainActor (String) -> Void,
        onResult: @escaping @MainActor (DictationCleanResult) -> Void,
        onCleanupFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard !meetingBusy() else { return }
        switch phase {
        case .idle:
            break
        case .failed:
            // An orphaned failure — the host view that owned it is gone, so
            // no retry button is left rendering it — must not wedge dictation
            // app-wide: a fresh start from ANY target clears it. The owning
            // view's own affordance still goes through retry(), never here.
            phase = .idle
        default:
            return // another dictation is actively in flight
        }

        activeTargetID = targetID
        liveText = ""
        lastRaw = nil
        phase = .loadingEngine
        // The engine is about to be used again — the idle countdown from the
        // previous dictation (if any) no longer applies.
        engineReleaseTask?.cancel()
        engineReleaseTask = nil

        var config = TranscriptionConfig.fromDefaults(defaults)
        config.windowSec = 10
        config.diarization = false

        let recorder = recorderFactory()
        self.recorder = recorder

        dictationTask = Task { @MainActor [weak self] in
            await self?.runDictation(mode: mode, recorder: recorder, config: config,
                                     onLiveText: onLiveText, onResult: onResult,
                                     onCleanupFailure: onCleanupFailure)
        }
    }

    /// Stops the mic; the already-running dictation task takes it from there
    /// (finish transcription → clean → onResult). During the engine-load
    /// spinner nothing recorded is worth keeping yet, so a stop there is the
    /// user walking away — it cancels. Otherwise a no-op unless a dictation
    /// is actively recording — calling it twice is safe, since the underlying
    /// task only ever resolves once regardless of how many times the mic is
    /// told to stop.
    func stop() {
        if phase == .loadingEngine {
            cancel()
            return
        }
        guard phase == .recording, let recorder else { return }
        recorder.stop()
    }

    /// Discards everything in flight and returns to idle. Unlike a cleanup
    /// failure, nothing here is kept for later — the caller is walking away.
    func cancel() {
        guard phase != .idle else { return }
        dictationTask?.cancel()
        dictationTask = nil
        recorder?.stop()
        recorder = nil
        liveText = ""
        lastRaw = nil
        activeTargetID = nil
        phase = .idle
        engineBecameIdle()
    }

    /// The meeting recorder is about to claim the (shared) engine slot.
    /// Recording → deliver what was said, same as `stop()`, then drop the
    /// resident engine once cleanup finishes. Idle with a warm engine → drop
    /// it immediately. Mid-flight (loading/cleaning) → flag the drop for
    /// whenever that in-flight work reaches idle.
    func meetingCaptureWillStart() {
        switch phase {
        case .recording:
            dropEngineAfterCleanup = true
            stop()
        case .idle, .failed:
            dropEngineImmediately()
        case .loadingEngine, .cleaning:
            dropEngineAfterCleanup = true
        }
    }

    /// Leaves `.failed` back to `.idle`. `liveText`/`lastRaw` are left intact —
    /// the field still shows the raw span the failed cleanup couldn't touch.
    func retry() {
        guard case .failed = phase else { return }
        activeTargetID = nil
        phase = .idle
    }

    // MARK: - Dictation flow

    private func runDictation(
        mode: DictationMode,
        recorder: MicRecording,
        config: TranscriptionConfig,
        onLiveText: @escaping @MainActor (String) -> Void,
        onResult: @escaping @MainActor (DictationCleanResult) -> Void,
        onCleanupFailure: (@MainActor (String) -> Void)?
    ) async {
        do {
            try await recorder.start()
        } catch {
            guard !Task.isCancelled else { return }
            finish(failed: "microphone failed to start: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        let transcriber: Transcriber
        do {
            transcriber = try await resolveTranscriber(config: config)
        } catch {
            recorder.stop()
            guard !Task.isCancelled else { return }
            finish(failed: "engine failed to load: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        phase = .recording

        let rawText: String
        do {
            rawText = try await capture(recorder: recorder, transcriber: transcriber, config: config,
                                        onLiveText: onLiveText)
        } catch {
            guard !Task.isCancelled else { return }
            // A thrown batch decode must not present as "nothing was said" —
            // that would silently drop whatever the user actually dictated.
            // A genuine empty decode (no throw) still takes the ordinary
            // empty-result path below.
            finish(failed: "transcription failed")
            return
        }
        guard !Task.isCancelled else { return }

        lastRaw = rawText
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An empty transcript with a latched capture error is NOT
            // "nothing was said" — the mic silently produced no usable
            // samples, and presenting that as a clean empty result would
            // hide a broken capture path.
            if recorder.lastError != nil {
                finish(failed: "microphone capture failed")
                return
            }
            phase = .idle
            activeTargetID = nil
            engineBecameIdle()
            onResult(DictationCleanResult(title: nil, text: ""))
            return
        }

        // The engine plays no part in the CLI cleanup — when the meeting
        // recorder has claimed the slot, release it now rather than after
        // cleanup, so the meeting's parked live pass overlaps only the decode
        // tail, never the (potentially slow) cleanup call.
        if dropEngineAfterCleanup {
            dropEngineAfterCleanup = false
            dropEngineImmediately()
        }

        phase = .cleaning
        await runCleanup(rawText: rawText, mode: mode,
                         onResult: onResult, onCleanupFailure: onCleanupFailure)
    }

    /// The cleanup step, split from `runDictation` (complexity): resolves the
    /// CLI runner and delivers either the cleaned result or — on any failure —
    /// the raw transcript through `onCleanupFailure`. "Raw text kept" must be
    /// true even on a batch-only provider, where no live chunk ever reached
    /// the field: the surface gets the transcript itself, not just the error.
    private func runCleanup(
        rawText: String,
        mode: DictationMode,
        onResult: @escaping @MainActor (DictationCleanResult) -> Void,
        onCleanupFailure: (@MainActor (String) -> Void)?
    ) async {
        guard let runner = runnerResolver() else {
            onCleanupFailure?(rawText)
            finish(failed: "cleanup failed — raw text kept")
            return
        }
        do {
            let result = try await DictationCleanService(runner: runner).clean(transcript: rawText, mode: mode)
            guard !Task.isCancelled else { return }
            phase = .idle
            activeTargetID = nil
            engineBecameIdle()
            onResult(result)
        } catch {
            guard !Task.isCancelled else { return }
            onCleanupFailure?(rawText)
            finish(failed: "cleanup failed — raw text kept")
        }
    }

    /// Runs until the mic stream ends (`stop()`/`cancel()`), buffering every
    /// sample and — when the engine supports it — feeding a live session at
    /// the same time. `recorder.samples` is single-consumer (`AsyncStream`),
    /// so this is the one place that reads it: the buffering loop re-yields
    /// each chunk into a private stream handed to the live session.
    ///
    /// The buffer is always populated, live session or not, so a mid-stream
    /// live failure (or a batch-only provider) still has something to fall
    /// back to — the meeting single-pass fallback's rule applied to a
    /// microphone-only stream. Throws only when the batch decode itself
    /// throws — the caller turns that into a visible failure rather than
    /// letting it masquerade as silence.
    private func capture(
        recorder: MicRecording,
        transcriber: Transcriber,
        config: TranscriptionConfig,
        onLiveText: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var buffer: [Float] = []
        let liveSession = transcriber.makeLiveSession(config: config)

        var teedStream: AsyncStream<[Float]>?
        var teedContinuation: AsyncStream<[Float]>.Continuation?
        if liveSession != nil {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            teedStream = stream
            teedContinuation = continuation
        }

        let feedTask = Task { @MainActor in
            for await chunk in recorder.samples {
                buffer.append(contentsOf: chunk)
                teedContinuation?.yield(chunk)
            }
            teedContinuation?.finish()
        }

        var liveOutput: TranscriptionOutput?
        if let liveSession, let teedStream {
            liveOutput = try? await liveSession.run(samples: teedStream) { [weak self] chunk in
                Task { @MainActor in
                    // A phase that has already moved past `.recording` means
                    // stop/cancel already resolved the dictation — a late
                    // chunk from the draining tail must not reopen it.
                    guard let self, self.phase == .recording else { return }
                    self.liveText += self.liveText.isEmpty ? chunk.text : " " + chunk.text
                    onLiveText(self.liveText)
                }
            }
        }
        await feedTask.value

        if let liveOutput, !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveOutput.text
        }
        guard !buffer.isEmpty else { return "" }
        // A genuine empty decode (no speech found) still returns "" and
        // takes the ordinary degenerate-stop path in the caller; only a
        // THROWN error propagates, since that means the buffer's contents
        // were never actually transcribed.
        let output = try await transcriber.transcribe(buffer, config: config) { _, _ in }
        return output.text
    }

    private func finish(failed message: String) {
        phase = .failed(message)
        engineBecameIdle()
    }

    // MARK: - Engine stickiness

    /// Whether this center still holds — or is mid-load about to hold — the
    /// shared physical engine slot. Read by the meeting recorder at record
    /// start to decide whether its live pass must park until `engineReleased`.
    var hasResidentEngine: Bool {
        warmTranscriber != nil || phase == .loadingEngine
    }

    /// The Settings pair the engine choice hangs on. Same keys and fallbacks
    /// as `MeetingRecorderCenter.defaultEngineFactory`, read from the injected
    /// defaults so tests can flip them.
    private func currentEngineKey() -> String {
        let provider = defaults.string(forKey: "transcription.provider") ?? "whisperkit"
        let model = defaults.string(forKey: "transcription.model") ?? "large-v3-v20240930"
        return provider + "|" + model
    }

    private func resolveTranscriber(config: TranscriptionConfig) async throws -> Transcriber {
        let key = currentEngineKey()
        if let warmTranscriber, warmEngineKey == key { return warmTranscriber }
        // Either no engine is resident, or Settings changed since it was
        // loaded — a stale engine must not outlive the owner's provider/model
        // choice. Dropped here (not via dropEngineImmediately) so the meeting
        // handshake callback doesn't fire for a slot we're about to refill.
        warmTranscriber = nil
        warmEngineKey = nil
        let transcriber = try await engineFactory(config)
        // A dictation cancelled while this load was in flight has already
        // made its engine-slot decision (dropped it via
        // `meetingCaptureWillStart()`, or armed a release timer via
        // `cancel()`) — caching here regardless would resurrect a resident
        // engine with nothing left counting down to release it. The caller
        // discards this instance immediately (`runDictation`'s own
        // cancellation check), so it is not lost, only left uncached.
        guard !Task.isCancelled else { return transcriber }
        warmTranscriber = transcriber
        warmEngineKey = key
        return transcriber
    }

    /// Called whenever a dictation reaches idle/failed and the engine is no
    /// longer actively in use: drops it right away if the meeting recorder
    /// asked for the slot, otherwise arms the idle-release timer.
    private func engineBecameIdle() {
        if dropEngineAfterCleanup {
            dropEngineAfterCleanup = false
            dropEngineImmediately()
        } else {
            armEngineReleaseTimer()
        }
    }

    private func armEngineReleaseTimer() {
        engineReleaseTask?.cancel()
        let ttl = engineIdleTTL
        engineReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ttl)
            guard !Task.isCancelled else { return }
            self?.warmTranscriber = nil
        }
    }

    private func dropEngineImmediately() {
        engineReleaseTask?.cancel()
        engineReleaseTask = nil
        warmTranscriber = nil
        warmEngineKey = nil
        // A meeting live pass parked on `hasResidentEngine` re-checks now. A
        // spurious fire (nothing was actually parked) is a guarded no-op on
        // the meeting side.
        engineReleased?()
    }
}

// MARK: - Environment

private struct DictationCenterKey: EnvironmentKey {
    static let defaultValue: DictationCenter? = nil  // nil default keeps ViewInspector tests safe
}

extension EnvironmentValues {
    var dictationCenter: DictationCenter? {
        get { self[DictationCenterKey.self] }
        set { self[DictationCenterKey.self] = newValue }
    }
}
