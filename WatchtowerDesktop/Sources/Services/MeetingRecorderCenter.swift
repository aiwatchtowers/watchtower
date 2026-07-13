import Foundation

/// Native-notification seam for transcript completion/failure, so
/// `MeetingRecorderCenter` is unit-testable without `UNUserNotificationCenter`
/// (which has no app-bundle context under `swift test` and crashes if invoked
/// there). Same shape as `TargetExtractNotifying`.
protocol MeetingTranscriptNotifying {
    func sendTranscriptReadyNotification(title: String)
    func sendTranscriptFailedNotification(reason: String)
}

extension NotificationService: MeetingTranscriptNotifying {}

/// App-wide, single-slot registry for a meeting recording and its transcription.
///
/// All state lives here (never view-local) so an in-flight recording — and the
/// transcription/summarization that follows it — survives navigating away from
/// the calendar event that started it. This is the "начал → ушёл → вернулся"
/// contract shared with `TargetExtractCenter`/`TrackScanCenter`: the button that
/// starts it, and any view that renders progress, can be torn down while the run
/// keeps mutating this `AppState`-held Center.
///
/// The audio file is preserved on disk through every downstream failure, and its
/// path is mirrored to `UserDefaults` so a recording captured before a crash can
/// be re-transcribed after relaunch (`restorePendingOnLaunch`).
@MainActor
@Observable
final class MeetingRecorderCenter {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(done: Int, total: Int)
        case summarizing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Calendar event the active/last recording belongs to; `nil` for ad-hoc.
    private(set) var currentEventID: String?
    /// Title snapshot for the active/last recording.
    private(set) var currentTitle: String?
    /// Audio file awaiting (re-)transcription after a failure or relaunch.
    private(set) var pendingAudioURL: URL?

    /// A recording, transcription, or summarization is in flight. `.failed` is
    /// not busy — a failed run can be retried or dismissed.
    var isBusy: Bool {
        switch phase {
        case .idle, .failed:
            return false
        case .recording, .transcribing, .summarizing:
            return true
        }
    }

    /// `UserDefaults` key mirroring the audio file awaiting transcription, so a
    /// recording survives a crash/relaunch.
    static let pendingAudioPathKey = "recorder.pendingAudioPath"

    private let recorderFactory: () -> AudioRecording
    private let engineFactory: (TranscriptionConfig) async throws -> TranscriptionEngine
    private let decode: (URL) throws -> [Float]
    private let notifier: MeetingTranscriptNotifying
    private let defaults: UserDefaults

    /// Recorder for the active recording; released once `stop()` is called.
    private var recorder: AudioRecording?

    /// `decode` is injectable for the same reason as `recorderFactory`/
    /// `engineFactory`: `AudioFileDecoder.decodePCM16k` drives `AVAudioConverter`,
    /// which cannot run under `swift test` (headless CoreAudio), so tests feed
    /// samples directly instead of a real audio file.
    init(
        recorderFactory: @escaping () -> AudioRecording = { SystemAudioRecorder() },
        engineFactory: @escaping (TranscriptionConfig) async throws -> TranscriptionEngine = MeetingRecorderCenter.defaultEngineFactory,
        decode: @escaping (URL) throws -> [Float] = AudioFileDecoder.decodePCM16k(url:),
        notifier: MeetingTranscriptNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard
    ) {
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.decode = decode
        self.notifier = notifier
        self.defaults = defaults
    }

    /// Production engine: loads the WhisperKit model named in Settings (default
    /// `large-v3`). Runs lazily on first `stop()`, so first use may download
    /// model weights. The `TranscriptionConfig` is unused here (the model name is
    /// a separate `@AppStorage` key); the parameter exists so tests can vary the
    /// engine per config.
    static func defaultEngineFactory(_ config: TranscriptionConfig) async throws -> TranscriptionEngine {
        let model = UserDefaults.standard.string(forKey: "transcription.model") ?? "large-v3"
        return try await WhisperKitEngine.load(modelName: model, downloadProgress: { _ in })
    }

    // MARK: Recording

    /// Starts a recording for `eventID` (nil = ad-hoc). No-op when already busy
    /// (single-slot guard). The audio path is persisted to `UserDefaults` before
    /// capture starts so a crash still leaves a recoverable pointer.
    func startRecording(eventID: String?, title: String?) async {
        guard !isBusy else { return }

        currentEventID = eventID
        currentTitle = title

        let recorder = recorderFactory()
        self.recorder = recorder

        do {
            let directory = Self.recordingsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("rec_\(Self.timestampComponent()).m4a")
            defaults.set(url.path, forKey: Self.pendingAudioPathKey)
            try await recorder.start(to: url)
            pendingAudioURL = url
            phase = .recording(startedAt: Date())
        } catch {
            // Start failed before any audio was captured: nothing to keep.
            self.recorder = nil
            currentEventID = nil
            currentTitle = nil
            clearPending()
            fail(error.localizedDescription)
        }
    }

    /// Stops the active recording and runs transcription → save. No-op unless a
    /// recording is in flight. The finalized audio is always preserved on disk.
    func stopAndProcess(runner: CLIRunnerProtocol, config: TranscriptionConfig) async {
        guard case .recording = phase, let recorder else { return }
        self.recorder = nil

        let result: RecordingResult
        do {
            result = try await recorder.stop()
        } catch {
            // The partial file (if any) and the pending pointer are kept.
            fail(error.localizedDescription)
            return
        }

        pendingAudioURL = result.audioURL
        defaults.set(result.audioURL.path, forKey: Self.pendingAudioPathKey)
        await transcribeAndSave(audioURL: result.audioURL, runner: runner, config: config)
    }

    /// Re-runs transcription from `pendingAudioURL` after a failure or relaunch.
    /// No-op when busy or when there is no pending audio.
    func retryTranscription(runner: CLIRunnerProtocol, config: TranscriptionConfig) async {
        guard !isBusy, let url = pendingAudioURL else { return }
        await transcribeAndSave(audioURL: url, runner: runner, config: config)
    }

    /// Points the Center at an existing audio file (re-transcribe from the UI).
    /// The caller then invokes `retryTranscription`. No-op when busy.
    func prepareRetry(audioURL: URL, eventID: String?, title: String?) {
        guard !isBusy else { return }
        pendingAudioURL = audioURL
        currentEventID = eventID
        currentTitle = title
        defaults.set(audioURL.path, forKey: Self.pendingAudioPathKey)
    }

    /// Clears a `.failed` phase back to `.idle`, keeping `pendingAudioURL` so the
    /// audio can still be retried later.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
    }

    /// Restores a recording captured before a crash. If the mirrored path still
    /// exists on disk, exposes it as `pendingAudioURL` (the UI offers to
    /// transcribe it); if the file is gone, clears the stale key.
    func restorePendingOnLaunch() {
        guard let path = defaults.string(forKey: Self.pendingAudioPathKey) else { return }
        if FileManager.default.fileExists(atPath: path) {
            pendingAudioURL = URL(fileURLWithPath: path)
        } else {
            clearPending()
        }
    }

    // MARK: Pipeline

    private func transcribeAndSave(audioURL: URL, runner: CLIRunnerProtocol, config: TranscriptionConfig) async {
        phase = .transcribing(done: 0, total: 0)

        let samples: [Float]
        do {
            samples = try decode(audioURL)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let engine: TranscriptionEngine
        do {
            engine = try await engineFactory(config)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let output: TranscriptionOutput
        do {
            output = try await runTranscription(WindowedTranscriber(engine: engine, config: config), samples: samples)
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("No speech recognized")
            return
        }

        phase = .summarizing
        do {
            let result = try await TranscriptSaveService(runner: runner).save(
                transcriptText: output.text,
                audioPath: audioURL.path,
                durationSec: samples.count / TranscriptionConfig.sampleRate,
                eventID: currentEventID,
                title: currentTitle,
                langStatsJSON: Self.encodeLangStats(output.langStats)
            )
            clearPending()
            phase = .idle
            let title = currentTitle ?? "Recording"
            // Recap failure is non-fatal — the transcript row is saved; flag the
            // retry in the notification rather than reporting a failure.
            notifier.sendTranscriptReadyNotification(
                title: result.recapOK ? title : "\(title) — transcript saved, recap needs retry"
            )
            currentEventID = nil
            currentTitle = nil
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Drives `WindowedTranscriber` on a detached task and consumes its progress
    /// on the main actor, so `phase` updates are ordered and never race the
    /// phase transitions around them.
    private func runTranscription(_ transcriber: WindowedTranscriber, samples: [Float]) async throws -> TranscriptionOutput {
        let (stream, continuation) = AsyncStream<(Int, Int)>.makeStream()
        let task = Task.detached { () -> Result<TranscriptionOutput, Error> in
            do {
                let output = try await transcriber.transcribe(samples: samples) { done, total in
                    continuation.yield((done, total))
                }
                continuation.finish()
                return .success(output)
            } catch {
                continuation.finish()
                return .failure(error)
            }
        }
        for await (done, total) in stream {
            phase = .transcribing(done: done, total: total)
        }
        return try await task.value.get()
    }

    // MARK: Helpers

    /// Enters the failed state and fires the failure notification. The audio file
    /// and `pendingAudioURL` are intentionally left untouched for retry.
    private func fail(_ message: String) {
        phase = .failed(message)
        notifier.sendTranscriptFailedNotification(reason: message)
    }

    private func clearPending() {
        pendingAudioURL = nil
        defaults.removeObject(forKey: Self.pendingAudioPathKey)
    }

    private static func encodeLangStats(_ stats: [String: Int]) -> String {
        guard !stats.isEmpty,
              let data = try? JSONEncoder().encode(stats),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func recordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/recordings", isDirectory: true)
    }

    private static func timestampComponent(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
