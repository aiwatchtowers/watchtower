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
    /// accumulated so far; onResult delivers the cleaned result exactly once.
    /// No-op while another dictation is active or the meeting recorder owns
    /// the engine slot — the button is disabled in both cases anyway, this is
    /// the belt-and-braces path.
    func start(targetID: String, mode: DictationMode,
               onLiveText: @escaping @MainActor (String) -> Void,
               onResult: @escaping @MainActor (DictationCleanResult) -> Void) {
        guard phase == .idle, !meetingBusy() else { return }

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
                                      onLiveText: onLiveText, onResult: onResult)
        }
    }

    /// Stops the mic; the already-running dictation task takes it from there
    /// (finish transcription → clean → onResult). No-op unless a dictation is
    /// actively recording — calling it twice is safe, since the underlying
    /// task only ever resolves once regardless of how many times the mic is
    /// told to stop.
    func stop() {
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
        onResult: @escaping @MainActor (DictationCleanResult) -> Void
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

        let rawText = await capture(recorder: recorder, transcriber: transcriber, config: config,
                                     onLiveText: onLiveText)
        guard !Task.isCancelled else { return }

        lastRaw = rawText
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle
            activeTargetID = nil
            engineBecameIdle()
            onResult(DictationCleanResult(title: nil, text: ""))
            return
        }

        phase = .cleaning
        guard let runner = runnerResolver() else {
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
    /// microphone-only stream.
    private func capture(
        recorder: MicRecording,
        transcriber: Transcriber,
        config: TranscriptionConfig,
        onLiveText: @escaping @MainActor (String) -> Void
    ) async -> String {
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
        // Swallowed on purpose: a failed batch decode degrades to "nothing
        // was said" rather than losing the dictation to an uncaught throw —
        // the empty result then takes the ordinary degenerate-stop path.
        let output = try? await transcriber.transcribe(buffer, config: config, progress: { _, _ in })
        return output?.text ?? ""
    }

    private func finish(failed message: String) {
        phase = .failed(message)
        engineBecameIdle()
    }

    // MARK: - Engine stickiness

    private func resolveTranscriber(config: TranscriptionConfig) async throws -> Transcriber {
        if let warmTranscriber { return warmTranscriber }
        let transcriber = try await engineFactory(config)
        warmTranscriber = transcriber
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
