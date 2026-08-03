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

/// App-wide registry for meeting capture and the post-processing that follows.
///
/// Capture and post-processing are **decoupled**: `captureState` covers the one
/// recording the machine can physically make, while `jobs` is a FIFO queue of
/// finished recordings waiting to be transcribed → diarized → saved. Starting a
/// recording is gated on capture alone (`isCapturing`), so back-to-back meetings
/// no longer wait for the previous transcription to finish.
///
/// Exactly one transcription engine is ever resident. A queued job never starts
/// while a recording is capturing — the recording's live pass owns that slot —
/// and conversely a recording that starts while a job is running parks its live
/// pass in `.waiting` until the job releases the slot. Nothing is lost meanwhile:
/// the recorder's sample stream buffers from second zero, so the live pass drains
/// the backlog when it finally loads (the same mechanism that already covers the
/// mid-recording engine load).
///
/// All state lives here (never view-local) so an in-flight recording — and the
/// transcription/summarization that follows it — survives navigating away from
/// the calendar event that started it. This is the "начал → ушёл → вернулся"
/// contract shared with `TargetExtractCenter`/`TrackScanCenter`: the button that
/// starts it, and any view that renders progress, can be torn down while the run
/// keeps mutating this `AppState`-held Center.
///
/// The audio file is preserved on disk through every downstream failure. A
/// `rec_X.meta` sidecar written next to it at record start mirrors the event
/// link/title, so a recording captured before a crash is recovered event-linked
/// on relaunch (`restorePendingOnLaunch`) — one sidecar per recording, so N
/// unprocessed recordings all come back. Once transcription succeeds the
/// transcript is also persisted next to the audio until the save lands, so
/// retrying a failed save never re-transcribes.
@MainActor
@Observable
final class MeetingRecorderCenter {

    // MARK: - State

    enum CaptureState: Equatable {
        case idle
        case recording(startedAt: Date)
    }

    /// One finished recording's post-processing run: queued behind whatever the
    /// queue is already working, then transcribed → diarized → saved.
    struct ProcessingJob: Identifiable {
        enum Phase: Equatable {
            case queued
            case transcribing(done: Int, total: Int)
            case diarizing
            case summarizing
            case failed(String)
        }

        let id = UUID()
        let audioURL: URL
        /// Calendar event this recording belongs to; nil for ad-hoc. Carried by
        /// the job (not the Center) so a recording saves against the event it
        /// was started for even when a later recording is already capturing.
        let eventID: String?
        let title: String?
        var phase: Phase = .queued
        /// Output of the recording's live pass when it produced usable text: the
        /// job then skips the decode + batch pass entirely (the single-pass
        /// contract). Nil → batch path from the audio file.
        var liveOutput: TranscriptionOutput?
        /// The recorder's reported duration, meaningful only alongside
        /// `liveOutput` — the batch path derives it from the decoded samples.
        var liveDurationSec: Int = 0
        /// Transcriber the recording's live pass loaded, handed over on Stop so
        /// a batch fallback never loads the engine a second time.
        var transcriber: Transcriber?
        /// Why this job's diarization post-pass failed (nil = roles rendered or
        /// disabled). Only informs the completion notification — never blocks —
        /// and survives a retry so a label-less persisted transcript keeps its
        /// flag when the retry short-circuits to it.
        var rolesError: String?
    }

    /// A finished recording with no transcript row yet: recovered from a crash
    /// (audio + `.meta` sidecar still on disk), migrated from the legacy
    /// single-slot `UserDefaults` pointer, dismissed out of a failed job, or
    /// pointed at explicitly by `prepareRetry`. Nothing here is processed
    /// automatically — the user opts in.
    struct RecoverableRecording: Identifiable, Equatable {
        let audioURL: URL
        let eventID: String?
        let title: String?

        var id: URL { audioURL }
    }

    private(set) var captureState: CaptureState = .idle
    /// The post-processing queue, oldest first. Read-only for the UI; a failed
    /// job stays here (visible, retriable) and never blocks the queue.
    private(set) var jobs: [ProcessingJob] = []
    private(set) var recoverable: [RecoverableRecording] = []
    /// A capture that failed before any audio existed (`recorder.start` threw):
    /// there is no file, so no job can carry the message.
    private(set) var captureError: String?

    /// Calendar event the active/last recording belongs to; `nil` for ad-hoc.
    private(set) var currentEventID: String?
    /// Title snapshot for the active/last recording.
    private(set) var currentTitle: String?

    /// Reads the voice-print database for the post-diarization matching pass.
    /// Set by AppState once the shared DB opens; nil (no DB yet, tests)
    /// disables voice matching — clusters keep their "Speaker N" labels, the
    /// full degradation path. A loader failure must return [] rather than
    /// throw: voice naming is a progressive enhancement like roles themselves.
    var voicePrintsLoader: (@Sendable () async -> [VoicePrint])?

    /// `.waiting` = a recording is capturing but a job still owns the engine
    /// slot, so the live engine is deliberately not loaded yet.
    enum LiveEngineState: Equatable { case off, waiting, loading, running, unavailable }
    struct LiveChunk: Equatable, Identifiable { let id: Int; let text: String; let language: String }

    private(set) var liveEngineState: LiveEngineState = .off
    private(set) var liveChunks: [LiveChunk] = []

    // MARK: - Legacy single-slot projection

    /// Single-slot view of the state above, kept so the existing recorder UI
    /// (capsule, recovered pill, "reload when the recorder settles" hooks) keeps
    /// working until the queue UI lands: capture wins, then the job the queue is
    /// working, then whatever is waiting for the user.
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(done: Int, total: Int)
        case diarizing
        case summarizing
        case failed(String)
    }

    var phase: Phase {
        if case let .recording(startedAt) = captureState { return .recording(startedAt: startedAt) }
        if let running = jobs.first(where: { $0.id == activeJobID }) {
            switch running.phase {
            case .queued: return .transcribing(done: 0, total: 0)
            case let .transcribing(done, total): return .transcribing(done: done, total: total)
            case .diarizing: return .diarizing
            case .summarizing: return .summarizing
            case let .failed(message): return .failed(message)
            }
        }
        if let captureError { return .failed(captureError) }
        if let message = jobs.last(where: { $0.phase.isFailed })?.phase.failureMessage {
            return .failed(message)
        }
        if !jobs.isEmpty { return .transcribing(done: 0, total: 0) }
        return .idle
    }

    /// Legacy pointer at "the recording the retry/recovered pill acts on": the
    /// active capture, else an explicitly prepared/recovered recording, else the
    /// newest failure, else the job at the head of the queue.
    var pendingAudioURL: URL? {
        if case .recording = captureState { return captureAudioURL }
        if let entry = recoverable.first { return entry.audioURL }
        if let failed = jobs.last(where: { $0.phase.isFailed }) { return failed.audioURL }
        return jobs.first?.audioURL
    }

    /// A recording is being captured, including a start still awaiting the
    /// recorder (see `isStarting`). This — never the queue — gates the
    /// Record/Join surfaces.
    var isCapturing: Bool {
        if isStarting { return true }
        if case .recording = captureState { return true }
        return false
    }

    /// Anything at all in flight: capture, or a job the queue is working. Only
    /// the re-transcribe affordance still needs this — it drives the legacy
    /// `prepareRetry`/`retryTranscription` pair, which has one slot.
    var isBusy: Bool { isCapturing || activeJobID != nil }

    /// `UserDefaults` keys of the pre-queue single-slot pointer. Read (and
    /// cleared) exactly once, by `restorePendingOnLaunch`, so a recording
    /// captured by an older build still recovers; nothing writes them any more —
    /// `rec_X.meta` sidecars replaced them.
    static let pendingAudioPathKey = "recorder.pendingAudioPath"
    static let pendingEventIDKey = "recorder.pendingEventID"
    static let pendingTitleKey = "recorder.pendingTitle"

    // MARK: - Internals

    /// Transcriber loaded at record-start for the live pass, handed to the
    /// recording's job on Stop so a single recording never loads it twice.
    private var loadedTranscriber: Transcriber?
    /// The running live transcription; its value is the final output, or nil when
    /// the live pass never ran or produced no usable text (→ batch fallback).
    /// Non-nil also means "the live pass holds the engine slot", which is what
    /// keeps a queued job from loading a second engine while the tail drains.
    private var liveTask: Task<TranscriptionOutput?, Never>?

    /// Bumped every time a new live pass starts (`startLivePass`) and again when
    /// a stop-time error orphans the in-flight one. `onChunk` closes over the
    /// value captured at its own start and only mutates `liveChunks` while that
    /// value still matches — so a stale append from a cancelled/orphaned task
    /// (still in flight because cancellation cannot interrupt an in-progress
    /// `await engine.transcribeWindow`) can never land in a *new* recording's
    /// `liveChunks` once one has started.
    private var liveGeneration = 0

    /// A recording whose live pass is waiting for the engine slot, held until
    /// the running job releases it.
    private struct PendingLiveStart {
        let recorder: AudioRecording
        let config: TranscriptionConfig
    }

    private var pendingLiveStart: PendingLiveStart?

    /// The job the queue is currently working; nil when the queue is parked.
    private var activeJobID: ProcessingJob.ID?
    /// Task of the most recently enqueued job. A new job's task awaits it first,
    /// which is what makes the queue FIFO and strictly serial.
    private var lastJobTask: Task<Void, Never>?
    /// Jobs parked waiting for the engine slot, resumed when capture (and its
    /// live pass) let go of it.
    private var engineSlotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Latched synchronously at the top of `startRecording`, before its first
    /// suspension point (`recorder.start`), and cleared when the start attempt
    /// resolves either way. Without it, two rapid start triggers (the Record
    /// button plus two Join surfaces share one Center) could both pass the
    /// `isCapturing` check-then-act across that suspension and double-start,
    /// orphaning the first recorder as unstoppable capture.
    private var isStarting = false

    /// Audio file of the active capture.
    private var captureAudioURL: URL?

    private let recorderFactory: () -> AudioRecording
    private let engineFactory: (TranscriptionConfig) async throws -> Transcriber
    private let diarizerFactory: (TranscriptionConfig) async throws -> SpeakerDiarizing
    private let decode: (URL) throws -> [Float]
    private let runnerResolver: () -> CLIRunnerProtocol?
    private let notifier: MeetingTranscriptNotifying
    private let defaults: UserDefaults
    /// Directory the recorder writes `rec_*` files into and `restorePendingOnLaunch`
    /// scans. Injectable so tests neither write to nor scan the user's real one.
    private let recordingsDirectory: URL

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
        diarizerFactory: @escaping (TranscriptionConfig) async throws -> SpeakerDiarizing = { try await FluidAudioDiarizer.load(clusteringThreshold: $0.diarizationThreshold) },
        decode: @escaping (URL) throws -> [Float] = AudioFileDecoder.decodePCM16k(url:),
        runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
        notifier: MeetingTranscriptNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL = MeetingRecorderCenter.defaultRecordingsDirectory()
    ) {
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.diarizerFactory = diarizerFactory
        self.decode = decode
        self.runnerResolver = runnerResolver
        self.notifier = notifier
        self.defaults = defaults
        self.recordingsDirectory = recordingsDirectory
    }

    /// Production factory: resolves the provider+model chosen in Settings
    /// (`transcription.provider`, default `whisperkit`; `transcription.model`,
    /// default `large-v3-v20240930` i.e. large-v3-turbo) via
    /// `TranscriptionProviderRegistry` and loads its `Transcriber`. Runs lazily
    /// on first use, so first use may download model weights. The
    /// `TranscriptionConfig` is unused here (provider/model are separate
    /// `@AppStorage` keys); the parameter exists so tests can vary the
    /// transcriber per config.
    static func defaultEngineFactory(_ config: TranscriptionConfig) async throws -> Transcriber {
        let providerID = UserDefaults.standard.string(forKey: "transcription.provider") ?? "whisperkit"
        let model = UserDefaults.standard.string(forKey: "transcription.model") ?? "large-v3-v20240930"
        let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
        return try await provider.makeTranscriber(model: model) { _ in }
    }

    // MARK: - Diarization post-pass

    /// Renders role-tagged text from the finished transcription. Every failure
    /// returns the plain text — roles are a progressive enhancement and must
    /// never fail the pipeline (spec §3.6) — but is logged and latched into the
    /// job's `rolesError` so the completion notification can flag the missing
    /// labels (the recap-failure precedent). `samples` avoids a re-decode when
    /// the batch path already has them.
    /// The returned utterances are the structured form of the same text
    /// (`text == TranscriptSegments.render(utterances)`); nil whenever roles
    /// were not rendered — the save then leaves `segments_json` NULL.
    /// `speakers` carries the per-cluster voice embeddings keyed by the final
    /// rendered labels (nil when the diarizer produced none — non-FluidAudio
    /// engines — or roles were not rendered); the save persists them to
    /// `speakers_json` so a later manual rename can learn a voice print.
    private func renderRoles(
        jobID: ProcessingJob.ID,
        output: TranscriptionOutput,
        audioURL: URL,
        samples: [Float]?,
        config: TranscriptionConfig
    ) async -> (text: String, utterances: [TranscriptUtterance]?, speakers: [SpeakerEmbedding]?) {
        guard config.diarization, !output.segments.isEmpty else { return (output.text, nil, nil) }
        updateJob(jobID) { $0.phase = .diarizing }
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
            let diarizer = try await diarizerFactory(config)
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
            // One dict for both RoleAssigner calls below, so the mega-cluster
            // suppression cannot apply to the transcript labels but not to the
            // embedding keys (or vice versa).
            let voiceNames = Self.filterMegaClusters(
                voiceNames: await matchVoiceNames(clusterEmbeddings: clusterEmbeddings),
                speakers: speakers)
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
            updateJob(jobID) { $0.rolesError = "no speakers detected" }
            return (output.text, nil, nil)
        } catch {
            print("[MeetingRecorder] diarization failed, saving without speaker labels: \(error.localizedDescription)")
            updateJob(jobID) { $0.rolesError = error.localizedDescription }
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

    /// Share of total diarized speech above which a cluster is read as a
    /// diarization under-split (several people merged into one cluster) rather
    /// than a genuinely dominant speaker.
    private static let megaClusterShareThreshold: Double = 0.4
    /// How many distinct clusters must be detected before the mega-cluster
    /// guard may fire. In a 1:1 the counterparty legitimately owns ~half the
    /// speech, so the guard must not fire there; with 4+ detected clusters a
    /// 40%+ cluster is far likelier an under-split than a real dominant
    /// speaker, and a wrong person-name on a merged cluster is worse than an
    /// anonymous "Speaker N".
    private static let megaClusterMinClusters = 4

    /// Strips voice-print names from suspiciously dominant clusters, so a
    /// cluster the diarizer merged several people into is never renamed to one
    /// of them — it falls back to a plain "Speaker N" label instead. Fires only
    /// in multi-speaker meetings; see `megaClusterShareThreshold` /
    /// `megaClusterMinClusters`. Pure (internal, not private, so it is testable
    /// without driving the whole Center).
    static func filterMegaClusters(voiceNames: [String: String],
                                   speakers: [SpeakerSegment]) -> [String: String] {
        var speech: [String: Double] = [:]
        for s in speakers {
            speech[s.speakerID, default: 0] += max(0, s.endSec - s.startSec)
        }
        let total = speech.values.reduce(0, +)
        guard speech.count >= megaClusterMinClusters, total > 0 else { return voiceNames }
        var filtered = voiceNames
        for (cluster, duration) in speech.sorted(by: { $0.key < $1.key }) {
            let share = duration / total
            guard share > megaClusterShareThreshold, let name = filtered[cluster] else { continue }
            // Silent suppression would look like voice matching randomly
            // stopped working.
            print("[MeetingRecorder] cluster \(cluster) holds \(Int((share * 100).rounded()))% "
                  + "of speech across \(speech.count) clusters — suppressing voice match "
                  + "\"\(name)\" (likely diarization under-split)")
            filtered[cluster] = nil
        }
        return filtered
    }

    // MARK: - Capture

    /// Starts a recording for `eventID` (nil = ad-hoc). No-op while a recording
    /// is already being captured; the processing queue never blocks a start.
    /// The `rec_X.meta` sidecar is written before capture starts, so a crash
    /// still leaves a recoverable, event-linked pointer.
    func startRecording(eventID: String?, title: String?, config: TranscriptionConfig = .fromDefaults()) async {
        guard !isCapturing else { return }
        // Close the check-then-act window across `recorder.start`: a second
        // start arriving while this one is suspended must see capture busy.
        isStarting = true
        defer {
            isStarting = false
            // A job parked on the engine slot must be woken once the start
            // resolves; a successful start keeps the slot and releases it in
            // `stopAndProcess` instead.
            if !isCapturing { releaseEngineSlot() }
        }

        currentEventID = eventID
        currentTitle = title

        let recorder = recorderFactory()
        self.recorder = recorder
        let url = recordingsDirectory.appendingPathComponent("rec_\(Self.timestampComponent()).caf")

        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            Self.writeMetaSidecar(eventID: eventID, title: title, for: url)
            try await recorder.start(to: url)
            captureAudioURL = url
            captureState = .recording(startedAt: Date())
            captureError = nil
            if activeJobID == nil, liveTask == nil {
                startLivePass(recorder: recorder, config: config)
            } else {
                // A job — or the previous recording's still-draining live tail —
                // owns the engine slot. The recorder's live stream buffers
                // unboundedly from second zero, so the live pass loads its engine
                // when the slot frees and catches up on the backlog.
                liveChunks = []
                liveEngineState = .waiting
                pendingLiveStart = PendingLiveStart(recorder: recorder, config: config)
            }
        } catch {
            // Start failed before any audio was captured: nothing to keep.
            self.recorder = nil
            captureAudioURL = nil
            currentEventID = nil
            currentTitle = nil
            Self.removeMetaSidecar(for: url)
            captureError = error.localizedDescription
            notifier.sendTranscriptFailedNotification(reason: error.localizedDescription)
        }
    }

    /// Loads the transcriber and, when it supports live (`makeLiveSession`
    /// returns non-nil), runs its live session over the recorder's live
    /// samples. Never fails the recording: a load/stream failure — or a
    /// provider that simply does not support live — only sets
    /// `liveEngineState` to `.unavailable` and leaves the batch fallback to
    /// handle stop. The loaded transcriber is stashed either way so the
    /// recording's job reuses it instead of loading twice.
    private func startLivePass(recorder: AudioRecording, config: TranscriptionConfig) {
        liveChunks = []
        liveEngineState = .loading
        loadedTranscriber = nil
        liveGeneration += 1
        let generation = liveGeneration
        liveTask = Task { [weak self] () -> TranscriptionOutput? in
            guard let self else { return nil }
            // Same fence as `liveChunks` below: an orphaned prior pass must not
            // describe the recording that has since taken over the indicator.
            let setState: @MainActor (LiveEngineState) -> Void = { state in
                guard self.liveGeneration == generation else { return }
                self.liveEngineState = state
            }
            let transcriber: Transcriber
            do {
                transcriber = try await self.engineFactory(config)
            } catch {
                await MainActor.run { setState(.unavailable) }
                return nil
            }
            await MainActor.run {
                guard self.liveGeneration == generation else { return }
                self.loadedTranscriber = transcriber
            }
            guard let liveSession = transcriber.makeLiveSession(config: config) else {
                await MainActor.run { setState(.unavailable) }
                return nil // provider has no live session → batch fallback from file
            }
            await MainActor.run { setState(.running) }
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

    /// Stops the active recording and enqueues it for post-processing, then
    /// awaits that job — the caller who pressed Stop waits for their own
    /// recording, while a NEW recording can start the moment capture ends.
    /// No-op unless a recording is in flight. The finalized audio is always
    /// preserved on disk, and stopping capture never depends on the
    /// `watchtower` CLI resolving — the runner is looked up only at the save
    /// step.
    func stopAndProcess(config: TranscriptionConfig) async {
        guard case .recording = captureState, let recorder else { return }
        self.recorder = nil
        let startedURL = captureAudioURL
        let eventID = currentEventID
        let title = currentTitle

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
            captureState = .idle
            captureAudioURL = nil
            // See `ownsLivePass` on the success path below: a recording still
            // `.waiting` for the slot must not cancel the previous recording's
            // in-flight live pass.
            let ownsLivePass = pendingLiveStart == nil
            pendingLiveStart = nil
            liveEngineState = .off
            if ownsLivePass {
                liveTask?.cancel()
                releaseLiveEngineSlot()
            } else {
                releaseEngineSlot()
            }
            // The audio captured so far stays on disk with its sidecar: surface
            // it as a failed job so Retry re-runs the batch path from the file.
            if let startedURL {
                var job = ProcessingJob(audioURL: startedURL, eventID: eventID, title: title)
                job.phase = .failed(error.localizedDescription)
                jobs.append(job)
            }
            notifier.sendTranscriptFailedNotification(reason: error.localizedDescription)
            return
        }

        captureState = .idle
        captureAudioURL = nil
        // Only a recording whose live pass actually STARTED can feed its job.
        // One that was still `.waiting` for the engine slot has no live output,
        // and the `liveTask` standing here belongs to the previous recording,
        // whose own Stop owns it — never this job.
        let ownsLivePass = pendingLiveStart == nil
        pendingLiveStart = nil // this recorder is finished either way
        liveEngineState = .off

        // Enqueued — and given its place in the chain — before the live tail is
        // drained, so the queue order is stop order and the legacy `phase` never
        // dips through `.idle` mid-run. The task cannot start before the engine
        // slot frees below, which is what guarantees it sees a fully built job.
        let job = ProcessingJob(audioURL: result.audioURL, eventID: eventID, title: title)
        jobs.append(job)
        let task = startJobTask(jobID: job.id, config: config)

        if ownsLivePass {
            // The stream is now finished, so awaiting the task finalizes the
            // tail. A usable result is saved directly — no re-decode.
            if let liveOutput = await liveTask?.value,
               !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateJob(job.id) {
                    $0.liveOutput = liveOutput
                    $0.liveDurationSec = result.durationSec
                }
            }
            // The engine the live pass loaded moves to the job, so a batch
            // fallback reuses it instead of loading a second one.
            updateJob(job.id) { $0.transcriber = loadedTranscriber }
            releaseLiveEngineSlot()
        } else {
            // Capture ended, but the previous recording's tail still holds the
            // engine; wake the queue anyway so it re-checks.
            releaseEngineSlot()
        }

        await task.value
    }

    /// Releases the engine slot a finished capture's live pass held and hands it
    /// on: to a recording that started while the tail was draining, otherwise to
    /// whatever the queue has parked. Split from clearing `captureState`, which
    /// happens the moment Stop is pressed — a new recording may start
    /// immediately, while the engine stays claimed until the tail has drained.
    private func releaseLiveEngineSlot() {
        liveTask = nil
        loadedTranscriber = nil
        liveGeneration += 1
        startPendingLivePass()
        releaseEngineSlot()
    }

    // MARK: - Retry / recovery

    /// Re-runs the pipeline for whatever the legacy retry/recovered pill points
    /// at (`pendingAudioURL`) and awaits it. When a persisted transcript from an
    /// earlier run (whose save failed) sits next to the audio, decode +
    /// transcription are skipped and save is re-invoked directly from it
    /// (spec §7). No-op when busy or when there is nothing pending.
    func retryTranscription(config: TranscriptionConfig) async {
        guard !isBusy else { return }
        if let entry = recoverable.first {
            recoverable.removeFirst()
            let job = ProcessingJob(audioURL: entry.audioURL, eventID: entry.eventID, title: entry.title)
            jobs.append(job)
            await startJobTask(jobID: job.id, config: config).value
            return
        }
        guard let failed = jobs.last(where: { $0.phase.isFailed }) else { return }
        // Re-enqueues the SAME job, so its latched `rolesError` still describes
        // the persisted transcript a short-circuiting retry re-sends.
        updateJob(failed.id) { $0.phase = .queued }
        await startJobTask(jobID: failed.id, config: config).value
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
        currentEventID = eventID
        currentTitle = title
        addRecoverable(RecoverableRecording(audioURL: audioURL, eventID: eventID, title: title), atHead: true)
    }

    /// Clears the failure the legacy pill shows. A failed job becomes a
    /// recoverable recording rather than disappearing, so its audio — and event
    /// link — stays retriable, exactly as the old `.failed → .idle` transition
    /// kept `pendingAudioURL`.
    func dismissFailure() {
        guard case .failed = phase else { return }
        if captureError != nil {
            captureError = nil
            return
        }
        guard let index = jobs.lastIndex(where: { $0.phase.isFailed }) else { return }
        let job = jobs.remove(at: index)
        addRecoverable(RecoverableRecording(audioURL: job.audioURL, eventID: job.eventID, title: job.title))
    }

    /// Forgets a recovered recording the user chose not to transcribe: drops the
    /// entry and its `.meta` sidecar so the "recovered" pill goes away for good
    /// — this session and on relaunch. The audio file is left on disk; the Go
    /// orphan sweep reclaims it like any other `rec_*` file. Only acts on the
    /// idle recovered state, never mid-capture — otherwise an in-flight
    /// recording would lose the sidecar that lets it recover from a crash.
    func dismissRecovered() {
        guard case .idle = captureState, !recoverable.isEmpty else { return }
        let entry = recoverable.removeFirst()
        Self.removeMetaSidecar(for: entry.audioURL)
    }

    /// Recovers every recording captured before a crash: each `rec_*.caf` in the
    /// recordings directory that still carries its `.meta` sidecar (the sidecar
    /// is removed on a successful save, so its presence means "never saved").
    /// The three legacy `UserDefaults` keys of the pre-queue single-slot pointer
    /// are read — and cleared — once here, so a recording captured by an older
    /// build recovers too.
    func restorePendingOnLaunch() {
        migrateLegacyPendingDefaults()
        for entry in Self.scanRecoverable(in: recordingsDirectory) {
            addRecoverable(entry)
        }
        // The legacy pill acts on the oldest entry; keep the event link/title it
        // would save under in step with it.
        if let first = recoverable.first {
            currentEventID = first.eventID
            currentTitle = first.title
        }
    }

    /// One-shot migration off the single-slot pointer. Deliberately does NOT
    /// write a `.meta` sidecar: the entry is already recoverable in memory, and
    /// the only window it would cover is a crash between this launch and the
    /// user acting on the pill.
    private func migrateLegacyPendingDefaults() {
        guard let path = defaults.string(forKey: Self.pendingAudioPathKey) else { return }
        let eventID = defaults.string(forKey: Self.pendingEventIDKey)
        let title = defaults.string(forKey: Self.pendingTitleKey)
        defaults.removeObject(forKey: Self.pendingAudioPathKey)
        defaults.removeObject(forKey: Self.pendingEventIDKey)
        defaults.removeObject(forKey: Self.pendingTitleKey)
        guard FileManager.default.fileExists(atPath: path) else { return }
        addRecoverable(RecoverableRecording(audioURL: URL(fileURLWithPath: path),
                                           eventID: eventID, title: title))
    }

    private func addRecoverable(_ entry: RecoverableRecording, atHead: Bool = false) {
        recoverable.removeAll { $0.audioURL == entry.audioURL }
        if atHead {
            recoverable.insert(entry, at: 0)
        } else {
            recoverable.append(entry)
        }
    }

    // MARK: - Queue

    /// Spawns the job's task behind the previously enqueued one. FIFO and
    /// strictly serial: the task waits for its predecessor, then for the engine
    /// slot, and only then runs.
    private func startJobTask(jobID: ProcessingJob.ID, config: TranscriptionConfig) -> Task<Void, Never> {
        let predecessor = lastJobTask
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.acquireEngineSlot(for: jobID)
            await self.runJob(jobID: jobID, config: config)
        }
        lastJobTask = task
        return task
    }

    /// Parks until no capture (and no draining live pass) owns the engine slot,
    /// then claims it. Claiming happens in the same main-actor step as the final
    /// check, so a `startRecording` racing this cannot also load a live engine.
    private func acquireEngineSlot(for jobID: ProcessingJob.ID) async {
        while isCapturing || liveTask != nil {
            await withCheckedContinuation { engineSlotWaiters.append($0) }
        }
        activeJobID = jobID
    }

    private func releaseEngineSlot() {
        let waiters = engineSlotWaiters
        engineSlotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// A recording that started while this job held the engine slot loads its
    /// live engine now and drains the samples buffered since second zero.
    private func startPendingLivePass() {
        guard case .recording = captureState, let pending = pendingLiveStart else { return }
        pendingLiveStart = nil
        startLivePass(recorder: pending.recorder, config: pending.config)
    }

    private func runJob(jobID: ProcessingJob.ID, config: TranscriptionConfig) async {
        defer {
            activeJobID = nil
            startPendingLivePass()
        }
        guard let job = self.job(jobID) else { return } // dismissed while queued

        // A transcript persisted by a run whose save failed re-saves directly:
        // no decode, no transcription, no re-diarization (spec §7). Its roles
        // flag describes exactly that text, so it is NOT reset here.
        if let persisted = Self.loadPersistedTranscript(audioURL: job.audioURL) {
            await save(jobID: jobID,
                       text: persisted.text,
                       utterances: persisted.utterances,
                       speakers: persisted.speakers,
                       durationSec: persisted.durationSec,
                       langStats: persisted.langStats)
            return
        }

        updateJob(jobID) { $0.rolesError = nil } // per-run state, reset at the run boundary
        if let liveOutput = job.liveOutput {
            await renderAndSave(jobID: jobID, output: liveOutput, samples: nil,
                                durationSec: job.liveDurationSec, config: config)
        } else {
            await transcribeAndSave(jobID: jobID, config: config)
        }
    }

    /// Batch path: decode the file + run the windowed transcriber over it. Also
    /// the crash-recovery and retry path.
    private func transcribeAndSave(jobID: ProcessingJob.ID, config: TranscriptionConfig) async {
        guard let job = self.job(jobID) else { return }
        updateJob(jobID) { $0.phase = .transcribing(done: 0, total: 0) }

        // Consume the reusable transcriber (if the live pass handed one over) up
        // front, before any early-return path below — so an abandoned engine from
        // a failed attempt is never left around for a later retry to pick up.
        let reusableTranscriber = job.transcriber
        updateJob(jobID) { $0.transcriber = nil }

        let samples: [Float]
        do {
            samples = try decode(job.audioURL)
        } catch {
            failJob(jobID, error.localizedDescription)
            return
        }

        let transcriber: Transcriber
        if let reusableTranscriber {
            transcriber = reusableTranscriber
        } else {
            do {
                transcriber = try await engineFactory(config)
            } catch {
                failJob(jobID, error.localizedDescription)
                return
            }
        }

        let output: TranscriptionOutput
        do {
            output = try await runTranscription(jobID: jobID, transcriber, samples: samples, config: config)
        } catch {
            failJob(jobID, error.localizedDescription)
            return
        }

        await renderAndSave(jobID: jobID, output: output, samples: samples,
                            durationSec: samples.count / TranscriptionConfig.sampleRate, config: config)
    }

    /// Shared tail of both paths: role rendering → persist next to the audio →
    /// save. `samples` is nil on the live path (no decode happened), which makes
    /// the roles decode the only decode of the file.
    private func renderAndSave(jobID: ProcessingJob.ID,
                               output: TranscriptionOutput,
                               samples: [Float]?,
                               durationSec: Int,
                               config: TranscriptionConfig) async {
        guard let job = self.job(jobID) else { return }
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failJob(jobID, "No speech recognized")
            return
        }
        let rendered = await renderRoles(jobID: jobID, output: output, audioURL: job.audioURL,
                                         samples: samples, config: config)
        // Persist the (role-tagged) transcript next to the audio so a failed
        // save is retried from the file instead of paying for a full
        // re-transcription — or a re-diarization (spec §7).
        Self.persistTranscript(text: rendered.text, utterances: rendered.utterances,
                               speakers: rendered.speakers, durationSec: durationSec,
                               langStats: output.langStats, audioURL: job.audioURL)
        await save(jobID: jobID, text: rendered.text, utterances: rendered.utterances,
                   speakers: rendered.speakers, durationSec: durationSec, langStats: output.langStats)
    }

    /// Save step: the only place the `watchtower` CLI is needed. Resolves the
    /// runner here — never earlier — so a missing CLI still leaves the recording
    /// stopped, the audio finalized, and the transcript persisted for retry.
    private func save(jobID: ProcessingJob.ID,
                      text: String,
                      utterances: [TranscriptUtterance]?,
                      speakers: [SpeakerEmbedding]?,
                      durationSec: Int,
                      langStats: [String: Int]) async {
        guard let job = self.job(jobID) else { return }
        updateJob(jobID) { $0.phase = .summarizing }
        guard let runner = runnerResolver() else {
            failJob(jobID, "watchtower CLI not found — the recording and transcript are kept for retry")
            return
        }
        do {
            let result = try await TranscriptSaveService(runner: runner).save(
                transcriptText: text,
                utterances: utterances,
                speakers: speakers,
                audioPath: job.audioURL.path,
                durationSec: durationSec,
                eventID: job.eventID,
                title: job.title,
                langStatsJSON: Self.encodeLangStats(langStats)
            )
            let rolesError = self.job(jobID)?.rolesError
            Self.removePersistedTranscript(audioURL: job.audioURL)
            Self.removeMetaSidecar(for: job.audioURL)
            jobs.removeAll { $0.id == jobID }
            recoverable.removeAll { $0.audioURL == job.audioURL }
            if !result.segmentsOK {
                // The CLI dropped the segments file (render mismatch = Go↔Swift
                // renderer drift, or a malformed payload). The transcript row is
                // saved either way; log so the drift is not invisible.
                print("[MeetingRecorder] CLI dropped segments: \(result.segmentsError ?? "unknown reason")")
            }
            let title = job.title ?? "Recording"
            // Recap/roles failures are non-fatal — the transcript row is saved;
            // flag them in the notification rather than reporting a failure.
            if !result.recapOK {
                notifier.sendTranscriptReadyNotification(title: "\(title) — transcript saved, recap needs retry")
            } else if result.chapters == .failed {
                // Auto-chapters failed after save (envelope-only signal, like
                // the recap sibling) — retry via the in-UI "Generate
                // chapters" button.
                notifier.sendTranscriptReadyNotification(title: "\(title) — transcript saved, chapters need retry")
            } else if rolesError != nil {
                notifier.sendTranscriptReadyNotification(title: "\(title) — saved without speaker labels")
            } else {
                notifier.sendTranscriptReadyNotification(title: title)
            }
        } catch {
            failJob(jobID, error.localizedDescription)
        }
    }

    /// Drives `Transcriber.transcribe` on a detached task and consumes its
    /// progress on the main actor, so the job's phase updates are ordered and
    /// never race the phase transitions around them.
    private func runTranscription(jobID: ProcessingJob.ID,
                                  _ transcriber: Transcriber,
                                  samples: [Float],
                                  config: TranscriptionConfig) async throws -> TranscriptionOutput {
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
            updateJob(jobID) { $0.phase = .transcribing(done: done, total: total) }
        }
        return try await task.value.get()
    }

    // MARK: - Helpers

    private func job(_ id: ProcessingJob.ID) -> ProcessingJob? {
        jobs.first { $0.id == id }
    }

    private func updateJob(_ id: ProcessingJob.ID, _ mutate: (inout ProcessingJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    /// Fails a job and fires the failure notification. The job stays in the
    /// queue (retriable, and never blocking what is behind it) and its audio
    /// file is intentionally left untouched.
    private func failJob(_ id: ProcessingJob.ID, _ message: String) {
        updateJob(id) { $0.phase = .failed(message) }
        notifier.sendTranscriptFailedNotification(reason: message)
    }

    // MARK: - Meta sidecar (crash recovery)

    /// Per-recording sidecar (`rec_X.meta`, the `rec_X.activity` naming family,
    /// so the Go daemon's orphan sweep reclaims it for free) holding the event
    /// link and title a recording must come back with after a crash. Written
    /// before capture starts, removed once the transcript is saved or the user
    /// dismisses the recovered recording — so "sidecar present" means "this
    /// recording was never saved".
    private struct MetaSidecar: Codable {
        let eventID: String?
        let title: String?
    }

    private static func metaURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("meta")
    }

    /// Best-effort: losing the sidecar only costs the event link of a recording
    /// that crashed mid-capture, never the audio.
    private static func writeMetaSidecar(eventID: String?, title: String?, for audioURL: URL) {
        guard let data = try? JSONEncoder().encode(MetaSidecar(eventID: eventID, title: title)) else { return }
        try? data.write(to: metaURL(for: audioURL), options: .atomic)
    }

    private static func removeMetaSidecar(for audioURL: URL) {
        try? FileManager.default.removeItem(at: metaURL(for: audioURL))
    }

    /// `rec_*.caf` files that still carry a `.meta` sidecar, oldest first (the
    /// names are timestamps, so lexicographic order is chronological).
    private static func scanRecoverable(in directory: URL) -> [RecoverableRecording] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("rec_") && $0.hasSuffix(".caf") }
            .sorted()
            .compactMap { name -> RecoverableRecording? in
                let audioURL = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: metaURL(for: audioURL)),
                      let meta = try? JSONDecoder().decode(MetaSidecar.self, from: data) else { return nil }
                return RecoverableRecording(audioURL: audioURL, eventID: meta.eventID, title: meta.title)
            }
    }

    // MARK: - Transcript persistence (retry save without re-transcribing)

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

    /// `nonisolated` so it can serve as the init's default argument (evaluated
    /// outside the main actor); it only reads `FileManager`.
    nonisolated static func defaultRecordingsDirectory() -> URL {
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

extension MeetingRecorderCenter.ProcessingJob.Phase {
    var isFailed: Bool { failureMessage != nil }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
