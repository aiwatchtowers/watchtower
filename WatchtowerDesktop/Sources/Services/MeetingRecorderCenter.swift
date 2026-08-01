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
/// be re-transcribed after relaunch (`restorePendingOnLaunch`). Once transcription
/// succeeds the transcript is also persisted next to the audio until the save
/// lands, so retrying a failed save never re-transcribes.
@MainActor
@Observable
final class MeetingRecorderCenter {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(done: Int, total: Int)
        case diarizing
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
    /// Why the last diarization post-pass failed (nil = roles rendered or
    /// disabled). Only informs the completion notification — never blocks.
    private(set) var lastRolesError: String?

    /// Reads the voice-print database for the post-diarization matching pass.
    /// Set by AppState once the shared DB opens; nil (no DB yet, tests)
    /// disables voice matching — clusters keep their "Speaker N" labels, the
    /// full degradation path. A loader failure must return [] rather than
    /// throw: voice naming is a progressive enhancement like roles themselves.
    var voicePrintsLoader: (@Sendable () async -> [VoicePrint])?

    enum LiveEngineState: Equatable { case off, loading, running, unavailable }
    struct LiveChunk: Equatable, Identifiable { let id: Int; let text: String; let language: String }

    private(set) var liveEngineState: LiveEngineState = .off
    private(set) var liveChunks: [LiveChunk] = []

    /// Transcriber loaded at record-start for the live pass, reused for the
    /// stop-time batch fallback so we never load twice on a single recording.
    private var loadedTranscriber: Transcriber?
    /// The running live transcription; its value is the final output, or nil when
    /// the live pass never ran or produced no usable text (→ batch fallback).
    private var liveTask: Task<TranscriptionOutput?, Never>?

    /// Bumped every time a new live pass starts (`startLivePass`) and again when
    /// a stop-time error orphans the in-flight one. `onChunk` closes over the
    /// value captured at its own start and only mutates `liveChunks` while that
    /// value still matches — so a stale append from a cancelled/orphaned task
    /// (still in flight because cancellation cannot interrupt an in-progress
    /// `await engine.transcribeWindow`) can never land in a *new* recording's
    /// `liveChunks` once one has started.
    private var liveGeneration = 0

    /// A recording, transcription, or summarization is in flight. `.failed` is
    /// not busy — a failed run can be retried or dismissed.
    var isBusy: Bool {
        switch phase {
        case .idle, .failed:
            return false
        case .recording, .transcribing, .diarizing, .summarizing:
            return true
        }
    }

    /// `UserDefaults` keys mirroring the audio file awaiting transcription plus
    /// the event link/title it belongs to, so a recording — and its Target/event
    /// association — survives a crash/relaunch and is recovered event-linked.
    static let pendingAudioPathKey = "recorder.pendingAudioPath"
    static let pendingEventIDKey = "recorder.pendingEventID"
    static let pendingTitleKey = "recorder.pendingTitle"

    private let recorderFactory: () -> AudioRecording
    private let engineFactory: (TranscriptionConfig) async throws -> Transcriber
    private let diarizerFactory: () async throws -> SpeakerDiarizing
    private let decode: (URL) throws -> [Float]
    private let runnerResolver: () -> CLIRunnerProtocol?
    private let notifier: MeetingTranscriptNotifying
    private let defaults: UserDefaults

    /// Recorder for the active recording; released once `stop()` is called.
    private var recorder: AudioRecording?

    /// `decode` is injectable for the same reason as `recorderFactory`/
    /// `engineFactory`: `AudioFileDecoder.decodePCM16k` drives `AVAudioConverter`,
    /// which cannot run under `swift test` (headless CoreAudio), so tests feed
    /// samples directly instead of a real audio file.
    ///
    /// `runnerResolver` is consulted only at the save step — stopping capture,
    /// finalizing the audio file, and transcribing must never depend on the
    /// `watchtower` CLI being locatable; a nil resolution fails visibly with
    /// the audio (and persisted transcript) kept for retry.
    init(
        recorderFactory: @escaping () -> AudioRecording = { SystemAudioRecorder() },
        engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber = MeetingRecorderCenter.defaultEngineFactory,
        diarizerFactory: @escaping () async throws -> SpeakerDiarizing = { try await FluidAudioDiarizer.load() },
        decode: @escaping (URL) throws -> [Float] = AudioFileDecoder.decodePCM16k(url:),
        runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
        notifier: MeetingTranscriptNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard
    ) {
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.diarizerFactory = diarizerFactory
        self.decode = decode
        self.runnerResolver = runnerResolver
        self.notifier = notifier
        self.defaults = defaults
    }

    /// Production factory: resolves the provider+model chosen in Settings
    /// (`transcription.provider`, default `whisperkit`; `transcription.model`,
    /// default `large-v3-v20240930` i.e. large-v3-turbo) via
    /// `TranscriptionProviderRegistry` and loads its `Transcriber`. Runs lazily
    /// on first `stop()`, so first use may download model weights. The
    /// `TranscriptionConfig` is unused here (provider/model are separate
    /// `@AppStorage` keys); the parameter exists so tests can vary the
    /// transcriber per config.
    static func defaultEngineFactory(_ config: TranscriptionConfig) async throws -> Transcriber {
        let providerID = UserDefaults.standard.string(forKey: "transcription.provider") ?? "whisperkit"
        let model = UserDefaults.standard.string(forKey: "transcription.model") ?? "large-v3-v20240930"
        let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
        return try await provider.makeTranscriber(model: model) { _ in }
    }

    /// Diarization post-pass: renders role-tagged text from the finished
    /// transcription. Every failure returns the plain text — roles are a
    /// progressive enhancement and must never fail the pipeline (spec §3.6) —
    /// but is logged and latched into `lastRolesError` so the completion
    /// notification can flag the missing labels (the recap-failure precedent).
    /// `samples` avoids a re-decode when the batch path already has them.
    /// The returned utterances are the structured form of the same text
    /// (`text == TranscriptSegments.render(utterances)`); nil whenever roles
    /// were not rendered — the save then leaves `segments_json` NULL.
    /// `speakers` carries the per-cluster voice embeddings keyed by the final
    /// rendered labels (nil when the diarizer produced none — non-FluidAudio
    /// engines — or roles were not rendered); the save persists them to
    /// `speakers_json` so a later manual rename can learn a voice print.
    private func renderRoles(
        output: TranscriptionOutput,
        audioURL: URL,
        samples: [Float]?,
        config: TranscriptionConfig
    ) async -> (text: String, utterances: [TranscriptUtterance]?, speakers: [SpeakerEmbedding]?) {
        guard config.diarization, !output.segments.isEmpty else { return (output.text, nil, nil) }
        phase = .diarizing
        do {
            let pcm: [Float]
            if let samples {
                pcm = samples
            } else {
                // The live path has no decoded samples; a long recording takes
                // seconds to decode, so keep it off the main actor.
                let decode = self.decode
                pcm = try await Task.detached { try decode(audioURL) }.value
            }
            let diarizer = try await diarizerFactory()
            let speakers = try await diarizer.diarize(pcm)
            // The sidecar parse is a full-file read (~36k lines per hour) —
            // off-main like the decode above.
            let activity = await Task.detached { MicActivity.load(for: audioURL) }.value
            // One embedding per cluster (the diarizer repeats the cluster's
            // centroid on every segment; first occurrence wins).
            var clusterEmbeddings: [String: [Float]] = [:]
            for s in speakers where clusterEmbeddings[s.speakerID] == nil {
                if let embedding = s.embedding {
                    clusterEmbeddings[s.speakerID] = embedding
                }
            }
            let voiceNames = await matchVoiceNames(clusterEmbeddings: clusterEmbeddings)
            if let utterances = RoleAssigner.assign(
                segments: output.segments, speakers: speakers,
                activity: activity, voiceNames: voiceNames
            ) {
                // Key the persisted embeddings by the SAME labels the
                // transcript renders (clusterLabels is what assign used).
                // A cluster that won zero transcript utterances (e.g. it only
                // covered silence) is filtered out — its label matches nothing
                // in the transcript, and shipping it would make the Go save
                // drop it as an orphan.
                let labels = RoleAssigner.clusterLabels(
                    speakers: speakers, activity: activity, voiceNames: voiceNames)
                let usedLabels = Set(utterances.map(\.speaker))
                let speakerEmbeddings = clusterEmbeddings
                    .compactMap { cluster, embedding -> SpeakerEmbedding? in
                        guard let label = labels[cluster], usedLabels.contains(label) else { return nil }
                        return SpeakerEmbedding(speaker: label, embedding: embedding)
                    }
                    .sorted { $0.speaker < $1.speaker } // deterministic payload
                return (TranscriptSegments.render(utterances), utterances,
                        speakerEmbeddings.isEmpty ? nil : speakerEmbeddings)
            }
            // Roles undeterminable (diarizer found no speakers) — flag it like
            // the error path so the notification stays honest.
            print("[MeetingRecorder] diarization found no speakers, saving without labels")
            lastRolesError = "no speakers detected"
            return (output.text, nil, nil)
        } catch {
            print("[MeetingRecorder] diarization failed, saving without speaker labels: \(error.localizedDescription)")
            lastRolesError = error.localizedDescription
            return (output.text, nil, nil)
        }
    }

    /// Voice matching (Level 1): each cluster embedding against the
    /// voice-print database, cosine ≥ threshold → the person's display name.
    /// Empty when there is nothing to match against — no loader (no DB),
    /// empty database, or no embeddings — which degrades to plain
    /// "Speaker N" labels. «Я» keeps absolute priority downstream
    /// (RoleAssigner.clusterLabels ignores a voiceName for the self cluster).
    private func matchVoiceNames(clusterEmbeddings: [String: [Float]]) async -> [String: String] {
        guard !clusterEmbeddings.isEmpty, let voicePrintsLoader else { return [:] }
        let prints = await voicePrintsLoader()
        guard !prints.isEmpty else { return [:] }
        var names: [String: String] = [:]
        for (cluster, embedding) in clusterEmbeddings {
            if let match = VoicePrintMatcher.bestMatch(embedding: embedding, prints: prints) {
                names[cluster] = match.displayName
            }
        }
        return names
    }

    // MARK: Recording

    /// Starts a recording for `eventID` (nil = ad-hoc). No-op when already busy
    /// (single-slot guard). The audio path is persisted to `UserDefaults` before
    /// capture starts so a crash still leaves a recoverable pointer.
    func startRecording(eventID: String?, title: String?, config: TranscriptionConfig = .fromDefaults()) async {
        guard !isBusy else { return }

        currentEventID = eventID
        currentTitle = title

        let recorder = recorderFactory()
        self.recorder = recorder

        do {
            let directory = Self.recordingsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("rec_\(Self.timestampComponent()).caf")
            persistPendingDefaults(audioURL: url)
            try await recorder.start(to: url)
            pendingAudioURL = url
            phase = .recording(startedAt: Date())
            startLivePass(recorder: recorder, config: config)
        } catch {
            // Start failed before any audio was captured: nothing to keep.
            self.recorder = nil
            currentEventID = nil
            currentTitle = nil
            clearPending()
            fail(error.localizedDescription)
        }
    }

    /// Loads the transcriber and, when it supports live (`makeLiveSession`
    /// returns non-nil), runs its live session over the recorder's live
    /// samples. Never fails the recording: a load/stream failure — or a
    /// provider that simply does not support live — only sets
    /// `liveEngineState` to `.unavailable` and leaves the batch fallback to
    /// handle stop. The loaded transcriber is stashed either way so the
    /// stop-time batch fallback reuses it instead of loading twice.
    private func startLivePass(recorder: AudioRecording, config: TranscriptionConfig) {
        liveChunks = []
        liveEngineState = .loading
        loadedTranscriber = nil
        liveGeneration += 1
        let generation = liveGeneration
        liveTask = Task { [weak self] () -> TranscriptionOutput? in
            guard let self else { return nil }
            let transcriber: Transcriber
            do {
                transcriber = try await self.engineFactory(config)
            } catch {
                await MainActor.run { self.liveEngineState = .unavailable }
                return nil
            }
            await MainActor.run { self.loadedTranscriber = transcriber }
            guard let liveSession = transcriber.makeLiveSession(config: config) else {
                await MainActor.run { self.liveEngineState = .unavailable }
                return nil // provider has no live session → batch fallback from file
            }
            await MainActor.run { self.liveEngineState = .running }
            do {
                return try await liveSession.run(samples: recorder.liveSamples) { chunk in
                    Task { @MainActor in
                        // Fences a stale append from an orphaned/cancelled prior
                        // live pass (see `liveGeneration`'s doc) against the
                        // NEW recording's `liveChunks`.
                        guard self.liveGeneration == generation else { return }
                        self.liveChunks.append(LiveChunk(id: chunk.index, text: chunk.text, language: chunk.language))
                    }
                }
            } catch {
                return nil // total engine failure → batch fallback from file
            }
        }
    }

    /// Stops the active recording and runs transcription → save. No-op unless a
    /// recording is in flight. The finalized audio is always preserved on disk,
    /// and stopping capture never depends on the `watchtower` CLI resolving —
    /// the runner is looked up only at the save step.
    func stopAndProcess(config: TranscriptionConfig) async {
        guard case .recording = phase, let recorder else { return }
        self.recorder = nil
        lastRolesError = nil // per-run state, reset at the run boundary

        let result: RecordingResult
        do {
            result = try await recorder.stop() // also finishes liveSamples
        } catch {
            // `recorder.stop()` finishes `liveSamples` before throwing, so the
            // live task is still draining the buffered backlog through the
            // (heavy) engine. Cancel it — `StreamingTranscriber.run` checks
            // `Task.isCancelled` so it stops promptly rather than grinding
            // through everything — and bump `liveGeneration` so any append
            // already in flight (cancellation cannot interrupt an in-progress
            // `await engine.transcribeWindow`) is fenced out of whatever
            // recording starts next instead of contaminating it.
            liveTask?.cancel()
            liveTask = nil
            loadedTranscriber = nil
            liveGeneration += 1
            fail(error.localizedDescription)
            return
        }

        pendingAudioURL = result.audioURL
        persistPendingDefaults(audioURL: result.audioURL)

        // Live path: the stream is now finished, so awaiting the task finalizes
        // the tail. A usable result is saved directly — no re-decode.
        if let liveTask {
            phase = .transcribing(done: 0, total: 0)
            let liveOutput = await liveTask.value
            self.liveTask = nil
            if let liveOutput,
               !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let durationSec = result.durationSec
                let rendered = await renderRoles(output: liveOutput, audioURL: result.audioURL,
                                                 samples: nil, config: config)
                Self.persistTranscript(text: rendered.text, utterances: rendered.utterances,
                                       speakers: rendered.speakers, durationSec: durationSec,
                                       langStats: liveOutput.langStats, audioURL: result.audioURL)
                await saveTranscript(
                    text: rendered.text,
                    utterances: rendered.utterances,
                    speakers: rendered.speakers,
                    durationSec: durationSec,
                    langStats: liveOutput.langStats,
                    audioURL: result.audioURL
                )
                loadedTranscriber = nil
                return
            }
        }

        // Fallback: today's decode + batch path (reuses the loaded engine if any).
        await transcribeAndSave(audioURL: result.audioURL, config: config)
    }

    /// Re-runs the pipeline from `pendingAudioURL` after a failure or relaunch.
    /// When a persisted transcript from an earlier run (whose save failed) sits
    /// next to the audio, decode + transcription are skipped and save is
    /// re-invoked directly from it (spec §7). No-op when busy or when there is
    /// no pending audio.
    func retryTranscription(config: TranscriptionConfig) async {
        guard !isBusy, let url = pendingAudioURL else { return }
        // The persisted short-circuit re-saves THIS run's already-rendered
        // text, so a latched roles failure still describes it — reset only
        // below, before the paths that re-run renderRoles.
        if let persisted = Self.loadPersistedTranscript(audioURL: url) {
            await saveTranscript(
                text: persisted.text,
                utterances: persisted.utterances,
                speakers: persisted.speakers,
                durationSec: persisted.durationSec,
                langStats: persisted.langStats,
                audioURL: url
            )
            return
        }
        lastRolesError = nil // per-run state, reset at the run boundary
        await transcribeAndSave(audioURL: url, config: config)
    }

    /// Points the Center at an existing audio file (re-transcribe from the UI).
    /// The caller then invokes `retryTranscription`. No-op when busy.
    ///
    /// An explicit "Re-transcribe" must produce fresh output, so any transcript
    /// sidecars left next to the audio by an earlier run are deleted here —
    /// otherwise `retryTranscription` would short-circuit to the stale persisted
    /// text instead of re-running the engine.
    func prepareRetry(audioURL: URL, eventID: String?, title: String?) {
        guard !isBusy else { return }
        Self.removePersistedTranscript(audioURL: audioURL)
        pendingAudioURL = audioURL
        currentEventID = eventID
        currentTitle = title
        persistPendingDefaults(audioURL: audioURL)
    }

    /// Clears a `.failed` phase back to `.idle`, keeping `pendingAudioURL` so the
    /// audio can still be retried later.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
    }

    /// Forgets a recovered recording the user chose not to transcribe: clears the
    /// pending pointer and its mirrored `UserDefaults` so the "recovered" pill
    /// goes away for good — this session and on relaunch. The audio file is left
    /// on disk; the Go orphan sweep reclaims it like any other `rec_*` file. Only
    /// acts on the idle recovered state, never mid-run — otherwise an in-flight
    /// recording would lose the pointer that lets it recover from a crash.
    func dismissRecovered() {
        guard case .idle = phase, pendingAudioURL != nil else { return }
        clearPending()
    }

    /// Restores a recording captured before a crash. If the mirrored path still
    /// exists on disk, exposes it as `pendingAudioURL` (the UI offers to
    /// transcribe it); if the file is gone, clears the stale key.
    func restorePendingOnLaunch() {
        guard let path = defaults.string(forKey: Self.pendingAudioPathKey) else { return }
        if FileManager.default.fileExists(atPath: path) {
            pendingAudioURL = URL(fileURLWithPath: path)
            // Restore the event link/title so a recovered recording saves
            // event-linked, not as ad-hoc.
            currentEventID = defaults.string(forKey: Self.pendingEventIDKey)
            currentTitle = defaults.string(forKey: Self.pendingTitleKey)
        } else {
            clearPending()
        }
    }

    // MARK: Pipeline

    private func transcribeAndSave(audioURL: URL, config: TranscriptionConfig) async {
        phase = .transcribing(done: 0, total: 0)

        // Capture and clear the reusable transcriber (if any) up front, before
        // any early-return path below — so a stale, already-consumed-or-abandoned
        // transcriber from a prior recording attempt is never left around for a
        // later same-session retry to pick up.
        let reusableTranscriber = loadedTranscriber
        loadedTranscriber = nil

        let samples: [Float]
        do {
            samples = try decode(audioURL)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let transcriber: Transcriber
        if let reusableTranscriber {
            transcriber = reusableTranscriber
        } else {
            do {
                transcriber = try await engineFactory(config)
            } catch {
                fail(error.localizedDescription)
                return
            }
        }

        let output: TranscriptionOutput
        do {
            output = try await runTranscription(transcriber, samples: samples, config: config)
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("No speech recognized")
            return
        }

        let durationSec = samples.count / TranscriptionConfig.sampleRate
        let rendered = await renderRoles(output: output, audioURL: audioURL, samples: samples, config: config)
        // Persist the (role-tagged) transcript next to the audio so a failed
        // save is retried from the file instead of paying for a full
        // re-transcription — or a re-diarization (spec §7).
        Self.persistTranscript(text: rendered.text, utterances: rendered.utterances,
                               speakers: rendered.speakers, durationSec: durationSec,
                               langStats: output.langStats, audioURL: audioURL)
        await saveTranscript(
            text: rendered.text,
            utterances: rendered.utterances,
            speakers: rendered.speakers,
            durationSec: durationSec,
            langStats: output.langStats,
            audioURL: audioURL
        )
    }

    /// Save step: the only place the `watchtower` CLI is needed. Resolves the
    /// runner here — never earlier — so a missing CLI still leaves the recording
    /// stopped, the audio finalized, and the transcript persisted for retry.
    private func saveTranscript(text: String,
                                utterances: [TranscriptUtterance]?,
                                speakers: [SpeakerEmbedding]?,
                                durationSec: Int,
                                langStats: [String: Int],
                                audioURL: URL) async {
        phase = .summarizing
        guard let runner = runnerResolver() else {
            fail("watchtower CLI not found — the recording and transcript are kept for retry")
            return
        }
        do {
            let result = try await TranscriptSaveService(runner: runner).save(
                transcriptText: text,
                utterances: utterances,
                speakers: speakers,
                audioPath: audioURL.path,
                durationSec: durationSec,
                eventID: currentEventID,
                title: currentTitle,
                langStatsJSON: Self.encodeLangStats(langStats)
            )
            Self.removePersistedTranscript(audioURL: audioURL)
            clearPending()
            phase = .idle
            if !result.segmentsOK {
                // The CLI dropped the segments file (render mismatch = Go↔Swift
                // renderer drift, or a malformed payload). The transcript row is
                // saved either way; log so the drift is not invisible.
                print("[MeetingRecorder] CLI dropped segments: \(result.segmentsError ?? "unknown reason")")
            }
            let title = currentTitle ?? "Recording"
            // Recap/roles failures are non-fatal — the transcript row is saved;
            // flag them in the notification rather than reporting a failure.
            if !result.recapOK {
                notifier.sendTranscriptReadyNotification(title: "\(title) — transcript saved, recap needs retry")
            } else if lastRolesError != nil {
                notifier.sendTranscriptReadyNotification(title: "\(title) — saved without speaker labels")
            } else {
                notifier.sendTranscriptReadyNotification(title: title)
            }
            currentEventID = nil
            currentTitle = nil
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Drives `Transcriber.transcribe` on a detached task and consumes its
    /// progress on the main actor, so `phase` updates are ordered and never
    /// race the phase transitions around them.
    private func runTranscription(_ transcriber: Transcriber, samples: [Float], config: TranscriptionConfig) async throws -> TranscriptionOutput {
        let (stream, continuation) = AsyncStream<(Int, Int)>.makeStream()
        let task = Task.detached { () -> Result<TranscriptionOutput, Error> in
            do {
                let output = try await transcriber.transcribe(samples, config: config) { done, total in
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
        defaults.removeObject(forKey: Self.pendingEventIDKey)
        defaults.removeObject(forKey: Self.pendingTitleKey)
    }

    /// Mirrors the pending audio path plus the current event link/title to
    /// `UserDefaults` so a crash before save recovers the recording fully — audio
    /// AND its event association — on the next launch. A nil event/title clears
    /// its key rather than leaving a stale value from a previous recording.
    private func persistPendingDefaults(audioURL: URL) {
        defaults.set(audioURL.path, forKey: Self.pendingAudioPathKey)
        if let currentEventID {
            defaults.set(currentEventID, forKey: Self.pendingEventIDKey)
        } else {
            defaults.removeObject(forKey: Self.pendingEventIDKey)
        }
        if let currentTitle {
            defaults.set(currentTitle, forKey: Self.pendingTitleKey)
        } else {
            defaults.removeObject(forKey: Self.pendingTitleKey)
        }
    }

    // MARK: Transcript persistence (retry save without re-transcribing)

    /// Transcript + metadata persisted next to the audio file (same basename,
    /// `.txt`/`.json`) right after transcription succeeds, removed on a
    /// successful save. While a save failure stands, retry re-invokes save
    /// straight from these files instead of re-transcribing.
    private struct PersistedTranscript {
        let text: String
        let utterances: [TranscriptUtterance]?
        let speakers: [SpeakerEmbedding]?
        let durationSec: Int
        let langStats: [String: Int]
    }

    /// Sidecar `.json` payload accompanying the persisted transcript text.
    /// `utterances`/`speakers` are optional so sidecars written before the
    /// segments/speaker-identity work still decode (they retry as
    /// segment-less/embedding-less saves).
    private struct PersistedTranscriptMeta: Codable {
        let durationSec: Int
        let langStats: [String: Int]
        var utterances: [TranscriptUtterance]?
        var speakers: [SpeakerEmbedding]?
    }

    private static func transcriptTextURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("txt")
    }

    private static func transcriptMetaURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("json")
    }

    /// Best-effort: a persistence failure only means a later save retry pays
    /// for a full re-transcription, so it is deliberately not surfaced.
    private static func persistTranscript(text: String,
                                          utterances: [TranscriptUtterance]?,
                                          speakers: [SpeakerEmbedding]?,
                                          durationSec: Int,
                                          langStats: [String: Int],
                                          audioURL: URL) {
        try? text.write(to: transcriptTextURL(for: audioURL), atomically: true, encoding: .utf8)
        let meta = PersistedTranscriptMeta(durationSec: durationSec, langStats: langStats,
                                           utterances: utterances, speakers: speakers)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: transcriptMetaURL(for: audioURL), options: .atomic)
        }
    }

    /// Both files must load cleanly (non-empty text + decodable metadata);
    /// anything less falls back to full re-transcription.
    private static func loadPersistedTranscript(audioURL: URL) -> PersistedTranscript? {
        guard let text = try? String(contentsOf: transcriptTextURL(for: audioURL), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? Data(contentsOf: transcriptMetaURL(for: audioURL)),
              let meta = try? JSONDecoder().decode(PersistedTranscriptMeta.self, from: data) else {
            return nil
        }
        return PersistedTranscript(text: text, utterances: meta.utterances, speakers: meta.speakers,
                                   durationSec: meta.durationSec, langStats: meta.langStats)
    }

    private static func removePersistedTranscript(audioURL: URL) {
        try? FileManager.default.removeItem(at: transcriptTextURL(for: audioURL))
        try? FileManager.default.removeItem(at: transcriptMetaURL(for: audioURL))
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
