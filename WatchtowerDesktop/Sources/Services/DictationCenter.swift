import SwiftUI
import WatchtowerCore

/// State machine driving one voice dictation: mic capture → live (or batch)
/// transcription → `DictationCleanService` cleanup → the caller's callbacks.
enum DictationPhase: Equatable {
    case idle, recording, paused, stopping, cleaning
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
    /// True from `start()` until the engine resolves (or the run ends). The
    /// mic is already hot and buffering while the engine loads, so loading
    /// presents as "already listening" (phase `.recording`) with this flag
    /// driving a badge — never as a dedicated visible phase.
    private(set) var isEngineLoading = false
    private(set) var activeTargetID: String?
    /// RMS of the latest sample chunk, updated by the buffering feed loop —
    /// the capsule's level bars. Reads 0 while paused, idle, or failed.
    private(set) var micLevel: Float = 0
    /// Recording time accumulated across closed spans; paused time never
    /// ticks. The open span (if any) starts at `spanStartedAt` —
    /// `elapsed(now:)` adds it on top.
    private(set) var elapsedAccumulated: Duration = .zero
    /// Start of the currently-open recording span (monotonic — a wall-clock
    /// jump must never distort the timer): set when recording actually starts
    /// and on every `resume()`; folded into `elapsedAccumulated` and nil'd on
    /// `pause()`, `stop()`, `cancel()`, and failure.
    private(set) var spanStartedAt: ContinuousClock.Instant?
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
    /// Consecutive sub-threshold silence (sample-clock seconds) that
    /// auto-pauses a `.recording` dictation — the mic never stays hot over an
    /// abandoned session.
    private let silenceAutoPauseAfter: Duration
    /// Time `.paused` may last before the center performs a normal Stop
    /// (finalize + clean + deliver) — pause never holds the mic indefinitely.
    private let pauseAutoStopAfter: Duration
    /// Per-chunk RMS below this counts as silence for the auto-pause.
    private let silenceRMSThreshold: Float

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
    /// Consecutive silence accumulated on the SAMPLE clock (chunk sample
    /// counts / 16 kHz), never wall-clock — reset by a loud chunk, `resume()`,
    /// and `start()`.
    private var silentSeconds: Double = 0
    /// Armed by `pause()`; cancelled by `resume()`/`stop()`/`cancel()`. Fires
    /// the pause-timeout auto-stop.
    private var pauseTimeoutTask: Task<Void, Never>?
    /// Set by `meetingCaptureWillStart()` while a dictation (or its engine
    /// load / cleanup) is still in flight: the completion path drops the
    /// resident engine outright instead of arming the idle-release timer.
    private var dropEngineAfterCleanup = false

    init(recorderFactory: @escaping () -> MicRecording = { MicRecorder() },
         engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber
             = MeetingRecorderCenter.defaultEngineFactory,
         runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
         defaults: UserDefaults = .standard,
         engineIdleTTL: Duration = .seconds(15 * 60),
         silenceAutoPauseAfter: Duration = .seconds(120),
         pauseAutoStopAfter: Duration = .seconds(300),
         silenceRMSThreshold: Float = 0.003) {
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.runnerResolver = runnerResolver
        self.defaults = defaults
        self.engineIdleTTL = engineIdleTTL
        self.silenceAutoPauseAfter = silenceAutoPauseAfter
        self.pauseAutoStopAfter = pauseAutoStopAfter
        self.silenceRMSThreshold = silenceRMSThreshold
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
        // Recording begins NOW from the user's point of view — the mic opens
        // and buffers before the engine resolves, so the engine load is a
        // flag over `.recording`, not a phase of its own.
        phase = .recording
        isEngineLoading = true
        micLevel = 0
        silentSeconds = 0
        elapsedAccumulated = .zero
        spanStartedAt = .now
        // The engine is about to be used again — the idle countdown from the
        // previous dictation (if any) no longer applies. Likewise a stale
        // pause-timeout from a previous session (e.g. one that failed while
        // paused) must never fire into this one.
        engineReleaseTask?.cancel()
        engineReleaseTask = nil
        cancelPauseTimeout()

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

    /// Pauses the dictation: the mic stays hot but the recorder gates its
    /// samples, so to the transcriber a pause is a seamless audio splice. The
    /// open recording span is folded into `elapsedAccumulated` — paused time
    /// never ticks. A no-op unless `.recording`.
    func pause() {
        guard phase == .recording else { return }
        recorder?.setPaused(true)
        foldOpenSpan()
        micLevel = 0
        phase = .paused
        armPauseTimeout()
    }

    /// Resumes a paused dictation into the SAME session — a new recording
    /// span opens now. A no-op unless `.paused`.
    func resume() {
        guard phase == .paused else { return }
        cancelPauseTimeout()
        silentSeconds = 0
        recorder?.setPaused(false)
        spanStartedAt = .now
        phase = .recording
    }

    /// Stops the mic and finalizes; the already-running dictation task takes
    /// it from there (wait for the engine if it is still loading, finish
    /// transcription → clean → onResult). `.stopping` covers the gap until
    /// transcription completes, then the existing `.cleaning` flow. Works
    /// from `.paused` exactly like from `.recording` — pause never becomes a
    /// trap the user can only cancel out of. Speech spoken during an engine
    /// load was buffered from t0 and is batch-decoded once the engine
    /// resolves — never discarded; `cancel()` is the only deliberate discard
    /// path (an engine-load FAILURE also loses the buffered speech — nothing
    /// was left that could decode it). A
    /// no-op in any other phase — calling it twice is safe, since the
    /// underlying task only ever resolves once regardless of how many times
    /// the mic is told to stop.
    func stop() {
        guard phase == .recording || phase == .paused else { return }
        cancelPauseTimeout()
        recorder?.stop()
        foldOpenSpan()
        phase = .stopping
    }

    /// Discards everything in flight and returns to idle. Unlike a cleanup
    /// failure, nothing here is kept for later — the caller is walking away.
    func cancel() {
        guard phase != .idle else { return }
        cancelPauseTimeout()
        dictationTask?.cancel()
        dictationTask = nil
        recorder?.stop()
        recorder = nil
        liveText = ""
        lastRaw = nil
        activeTargetID = nil
        phase = .idle
        isEngineLoading = false
        foldOpenSpan()
        micLevel = 0
        engineBecameIdle()
    }

    /// The meeting recorder is about to claim the (shared) engine slot.
    /// Recording (even while the engine is still loading), paused, or already
    /// stopping → finalize: deliver what was said, same as `stop()`, then
    /// drop the resident engine as soon as transcription completes — speech
    /// buffered during an engine load is real and gets delivered, never
    /// cancelled. Idle with a warm engine → drop it immediately. Cleaning →
    /// the engine plays no part in the CLI cleanup — drop it right away while
    /// the cleanup runs to completion and still delivers its result.
    func meetingCaptureWillStart() {
        switch phase {
        case .recording, .paused, .stopping:
            // For `.stopping` (already finalizing) the extra stop() is a
            // harmless no-op: the flag alone routes the completing run
            // through the engine drop. `.recording` and `.paused` both
            // finalize through stop().
            dropEngineAfterCleanup = true
            stop()
        case .idle, .failed, .cleaning:
            dropEngineImmediately()
        }
    }

    /// Recording time elapsed as of `now` (monotonic): the closed spans plus
    /// the currently-open one (if any). Paused time never ticks — `pause()`
    /// folds the open span and nils `spanStartedAt`, freezing this value.
    func elapsed(now: ContinuousClock.Instant = .now) -> Duration {
        elapsedAccumulated + (spanStartedAt.map { $0.duration(to: now) } ?? .zero)
    }

    /// Closes the open recording span into `elapsedAccumulated`. A no-op when
    /// no span is open (e.g. `stop()` from `.paused`).
    private func foldOpenSpan() {
        guard let start = spanStartedAt else { return }
        elapsedAccumulated += start.duration(to: .now)
        spanStartedAt = nil
    }

    /// Leaves `.failed` back to `.idle`. `liveText`/`lastRaw` are left intact —
    /// the field still shows the raw span the failed cleanup couldn't touch.
    func retry() {
        guard case .failed = phase else { return }
        activeTargetID = nil
        phase = .idle
        isEngineLoading = false
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
            NSLog("[Dictation] mic failed to start: %@", String(describing: error))
            guard !Task.isCancelled else { return }
            finish(failed: "microphone failed to start: \(error.localizedDescription)")
            return
        }
        // A stop/cancel that landed while `recorder.start()` was still
        // suspended may have caught the recorder before its engine actually
        // ran — `MicRecorder` latches the stop and backs out, but the engine
        // may also have come hot in the races the latch can't cover. Now that
        // start() has completed, a second stop() is a REAL stop (idempotent
        // on the recorder side), so nothing can leave the mic hot. The flow
        // then continues to its natural resolution — the finished sample
        // stream resolves through the ordinary empty/degenerate path.
        if phase != .recording && phase != .paused {
            recorder.stop()
        }
        guard !Task.isCancelled else { return }

        // Buffering starts BEFORE the engine resolves: every sample from t0
        // lands in the buffer (and the teed stream), so speech spoken during
        // a cold engine load is never lost.
        let buffers = startBuffering(recorder: recorder)

        let transcriber: Transcriber
        do {
            transcriber = try await resolveTranscriber(config: config)
        } catch {
            NSLog("[Dictation] engine failed to load: %@", String(describing: error))
            recorder.stop()
            await buffers.feedTask?.value
            guard !Task.isCancelled else { return }
            finish(failed: "engine failed to load: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }
        isEngineLoading = false

        let rawText: String
        do {
            rawText = try await capture(transcriber: transcriber, buffers: buffers, config: config,
                                        onLiveText: onLiveText)
        } catch {
            NSLog("[Dictation] batch transcription failed: %@", String(describing: error))
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
            if let captureError = recorder.lastError {
                NSLog("[Dictation] microphone capture failed: %@", String(describing: captureError))
                finish(failed: "microphone capture failed")
                return
            }
            phase = .idle
            isEngineLoading = false
            micLevel = 0
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
            NSLog("[Dictation] cleanup runner unavailable (CLI not found), raw text kept")
            onCleanupFailure?(rawText)
            finish(failed: "cleanup failed — raw text kept")
            return
        }
        do {
            let result = try await DictationCleanService(runner: runner).clean(transcript: rawText, mode: mode)
            guard !Task.isCancelled else { return }
            phase = .idle
            isEngineLoading = false
            micLevel = 0
            activeTargetID = nil
            engineBecameIdle()
            onResult(result)
        } catch {
            NSLog("[Dictation] cleanup failed, raw text kept: %@", String(describing: error))
            guard !Task.isCancelled else { return }
            onCleanupFailure?(rawText)
            finish(failed: "cleanup failed — raw text kept")
        }
    }

    /// The always-on capture plumbing between the mic and the engine, built
    /// before the engine resolves. `recorder.samples` is single-consumer
    /// (`AsyncStream`), so the feed task is the one place that reads it: it
    /// appends every chunk to `buffer` from t0 and re-yields it into the
    /// teed stream, so a live session that only starts once the engine has
    /// loaded still catches up on everything said meanwhile.
    @MainActor
    private final class CaptureBuffers {
        let teedStream: AsyncStream<[Float]>
        let teedContinuation: AsyncStream<[Float]>.Continuation
        var buffer: [Float] = []
        var feedTask: Task<Void, Never>?

        init() {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            teedStream = stream
            teedContinuation = continuation
        }
    }

    private func startBuffering(recorder: MicRecording) -> CaptureBuffers {
        let buffers = CaptureBuffers()
        buffers.feedTask = Task { @MainActor [weak self] in
            for await chunk in recorder.samples {
                buffers.buffer.append(contentsOf: chunk)
                buffers.teedContinuation.yield(chunk)
                let rms = chunk.isEmpty
                    ? Float(0)
                    : (chunk.reduce(into: Float(0)) { $0 += $1 * $1 } / Float(chunk.count)).squareRoot()
                // Only a `.recording` chunk drives the meter — a late chunk
                // draining after pause()/stop() must not overwrite the reset.
                // (trackSilence carries its own phase guard.)
                if let self, self.phase == .recording { self.micLevel = rms }
                self?.trackSilence(rms: rms, sampleCount: chunk.count)
            }
            buffers.teedContinuation.finish()
        }
        return buffers
    }

    /// Silence auto-pause, driven by the SAMPLE clock (never wall-clock):
    /// each sub-threshold chunk adds its duration in samples/16 kHz, a loud
    /// chunk resets the counter, and crossing `silenceAutoPauseAfter` pauses.
    /// Only `.recording` chunks count — the draining tail after a stop (or a
    /// chunk racing a manual pause) must never re-trigger it.
    private func trackSilence(rms: Float, sampleCount: Int) {
        guard phase == .recording else { return }
        guard rms < silenceRMSThreshold else {
            silentSeconds = 0
            return
        }
        silentSeconds += Double(sampleCount) / 16_000
        if silentSeconds > silenceAutoPauseAfter / .seconds(1) {
            pause()
        }
    }

    /// The pause-timeout auto-stop: `.paused` past `pauseAutoStopAfter`
    /// performs a NORMAL stop — finalize + clean + deliver, nothing lost,
    /// nothing left holding the mic or the engine.
    private func armPauseTimeout() {
        pauseTimeoutTask?.cancel()
        let timeout = pauseAutoStopAfter
        pauseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.stop()
        }
    }

    private func cancelPauseTimeout() {
        pauseTimeoutTask?.cancel()
        pauseTimeoutTask = nil
    }

    /// Runs until the mic stream ends (`stop()`/`cancel()`) and produces the
    /// raw transcript. When the mic is still open and the engine supports it,
    /// a live session runs over the teed stream — it buffered everything
    /// since t0, so it catches up on speech spoken during the engine load. A
    /// mic already stopped (stop during load) or a batch-only provider skips
    /// the live session; the teed continuation is finished so the unconsumed
    /// stream stops accumulating chunks, and the buffer alone is decoded.
    ///
    /// The buffer is always populated, live session or not, so a mid-stream
    /// live failure (or a batch-only provider) still has something to fall
    /// back to — the meeting single-pass fallback's rule applied to a
    /// microphone-only stream. Throws only when the batch decode itself
    /// throws — the caller turns that into a visible failure rather than
    /// letting it masquerade as silence.
    private func capture(
        transcriber: Transcriber,
        buffers: CaptureBuffers,
        config: TranscriptionConfig,
        onLiveText: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        // Skip the live session only when the mic already stopped
        // (`.stopping` — a stop landed during the engine load); a PAUSE
        // during the load must not kill live transcription for the rest of
        // the session — the mic is still open and resume() re-opens the flow.
        let micStillOpen = phase == .recording || phase == .paused
        let liveSession = micStillOpen ? transcriber.makeLiveSession(config: config) : nil

        var liveOutput: TranscriptionOutput?
        if let liveSession {
            do {
                liveOutput = try await liveSession.run(samples: buffers.teedStream) { [weak self] chunk in
                    Task { @MainActor in
                        // A phase that has already moved past `.recording` means
                        // stop/cancel already resolved the recording span — a
                        // late chunk from the draining tail must not reopen it.
                        // (On a stop the final text still arrives through the
                        // session's return value, so nothing is lost.)
                        guard let self, self.phase == .recording else { return }
                        self.liveText += self.liveText.isEmpty ? chunk.text : " " + chunk.text
                        onLiveText(self.liveText)
                    }
                }
            } catch {
                NSLog("[Dictation] live session failed, falling back to batch decode: %@",
                      String(describing: error))
                liveOutput = nil
            }
        }
        // Finish the teed continuation unconditionally: with no live session
        // nothing will ever consume it, and a live session that returned (or
        // threw) early is done with it — either way it must stop accumulating
        // chunks (yields onto a finished continuation are dropped; the buffer
        // keeps the audio).
        buffers.teedContinuation.finish()
        await buffers.feedTask?.value

        if let liveOutput, !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveOutput.text
        }
        guard !buffers.buffer.isEmpty else { return "" }
        // A genuine empty decode (no speech found) still returns "" and
        // takes the ordinary degenerate-stop path in the caller; only a
        // THROWN error propagates, since that means the buffer's contents
        // were never actually transcribed.
        let output = try await transcriber.transcribe(buffers.buffer, config: config) { _, _ in }
        return output.text
    }

    private func finish(failed message: String) {
        // A failure can land while `.paused` (e.g. the engine load throwing) —
        // the armed pause-timeout must not fire a stale stop() into whatever
        // dictation comes next.
        cancelPauseTimeout()
        phase = .failed(message)
        isEngineLoading = false
        foldOpenSpan()
        micLevel = 0
        engineBecameIdle()
    }

    // MARK: - Engine stickiness

    /// Whether this center still holds — or is mid-load about to hold — the
    /// shared physical engine slot. Read by the meeting recorder at record
    /// start to decide whether its live pass must park until `engineReleased`.
    var hasResidentEngine: Bool {
        warmTranscriber != nil || (phase != .idle && isEngineLoading)
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
            guard !Task.isCancelled, let self else { return }
            self.warmTranscriber = nil
            self.warmEngineKey = nil
            // Every engine-drop path wakes a parked meeting live pass — a
            // spurious fire is a guarded no-op on the meeting side.
            self.engineReleased?()
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
