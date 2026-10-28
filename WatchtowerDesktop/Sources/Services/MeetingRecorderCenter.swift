import AVFoundation
import Foundation
import WatchtowerCore

/// Native-notification seam for transcript completion/failure, so
/// `MeetingRecorderCenter` is unit-testable without `UNUserNotificationCenter`
/// (which has no app-bundle context under `swift test` and crashes if invoked
/// there). Same shape as `TargetExtractNotifying`.
protocol MeetingTranscriptNotifying {
    func sendTranscriptReadyNotification(title: String)
    func sendTranscriptFailedNotification(reason: String)
    func sendVoicesToLabelNotification(title: String, count: Int, transcriptID: Int64)
    /// The live capture has had no call audio for `CallAudioWatch.minGapSec`
    /// (see `callAudioSilentSince`) — the owner is usually in the call app,
    /// not looking at Watchtower, so the pill alone would go unseen.
    func sendCallAudioSilentNotification()
    /// Takes that notification back once the call audio returns or the
    /// capture ends, so a stale warning never lingers in Notification Center.
    func withdrawCallAudioSilentNotification()
}

/// The "check your output device" hint every call-audio surface ends on.
let callAudioOutputHint = "check that the call plays through this Mac's output device."

extension NotificationService: MeetingTranscriptNotifying {}

/// App-wide registry for meeting capture and the post-processing that follows.
///
/// Capture and post-processing are **decoupled**: `captureState` covers the one
/// recording the machine can physically make, while `jobs` is a serial queue of
/// finished recordings (stop order; see `startJobTask` for which one goes next)
/// waiting to be transcribed → diarized → saved. Starting a
/// recording is gated on capture alone (`isCapturing`), so back-to-back meetings
/// no longer wait for the previous transcription to finish.
///
/// Exactly one transcription engine is ever resident. A queued job that has to
/// transcribe (the batch path) never starts while a recording is capturing —
/// the recording's live pass owns that slot — and conversely a recording that
/// starts while such a job is transcribing parks its live pass in `.waiting`
/// until the job releases the slot (when its transcription is over, not when
/// it is saved). Nothing is lost meanwhile: the recorder's sample
/// stream buffers from second zero, so the live pass drains the backlog when it
/// finally loads (the same mechanism that already covers the mid-recording
/// engine load). A job that already has its text — the live pass's output, or
/// a transcript kept from an earlier run — needs no engine: it renders roles
/// and saves while the next meeting captures, and never parks that meeting's
/// live pass (`engineJobID` vs `activeJobID`).
///
/// The **warm slot** is the fourth state of that single-engine invariant: an
/// engine can be held by the capture's live pass, a draining live tail, a job —
/// or parked idle in `warmTranscriber`, ready for the next recording so Record
/// skips the "Loading model…" wait. A finished job always parks its engine back
/// into the slot (unless preloading is off or the run failed); the 30-second
/// warm-policy poll (`WarmEnginePolicy`) is the single decision point for
/// unloading it, and also pre-loads the engine when a meeting is ongoing or
/// starts within `WarmEnginePolicy.prewarmLead`. Both load sites go through
/// `takeWarmOrLoad`, which awaits an in-flight prewarm first — so a recording
/// started mid-prewarm still produces exactly one load, never two engines.
///
/// All state lives here (never view-local) so an in-flight recording — and the
/// transcription/summarization that follows it — survives navigating away from
/// the calendar event that started it. This is the "начал → ушёл → вернулся"
/// contract shared with `TargetExtractCenter`/`TrackScanCenter`: the button that
/// starts it, and any view that renders progress, can be torn down while the run
/// keeps mutating this `AppState`-held Center.
///
/// The audio file is preserved on disk through every downstream failure. A
/// `pending_transcripts` row written at record start (`pendingStore`, #604
/// S3/S4 — it replaced the `rec_X.meta` sidecar) holds the event link/title, so
/// a recording captured before a crash is recovered event-linked on relaunch
/// (`restorePendingOnLaunch`) — one row per recording, so N unprocessed
/// recordings all come back; an audio file with no row and no saved transcript
/// (the database was not open yet) comes back too, without its link. Once
/// transcription succeeds the transcript is kept in the row until the save
/// lands, so retrying a failed save never re-transcribes.
@MainActor
@Observable
final class MeetingRecorderCenter {

    // MARK: - State

    enum CaptureState: Equatable {
        case idle
        case recording(startedAt: Date)
    }

    /// A loaded engine together with the provider+model identity (`engineKey()`)
    /// it was loaded FOR, read at the load site and carried from there to the
    /// warm slot. The two travel as one value precisely because they must not
    /// be re-derived later: Settings can switch provider/model while a job is
    /// transcribing, and stamping the finished engine with the key of the
    /// moment it happened to finish would park it under an identity it does
    /// not have — the next recording would then be served the wrong model.
    struct LoadedEngine {
        let transcriber: Transcriber
        let key: String
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
        /// Saves with `--private` (MEETPRIV-01); `setJobPrivate` until the save.
        var isPrivate: Bool
        var phase: Phase = .queued
        /// Output of the recording's live pass when it produced usable text: the
        /// job then skips the decode + batch pass entirely (the single-pass
        /// contract). Nil → batch path from the audio file.
        var liveOutput: TranscriptionOutput?
        /// The recorder's reported duration, meaningful only alongside
        /// `liveOutput` — the batch path derives it from the decoded samples.
        var liveDurationSec: Int = 0
        /// Engine the recording's live pass loaded, handed over on Stop so a
        /// batch fallback never loads one a second time — carrying the key it
        /// was loaded for, which is what the job's park stamps it with.
        var engine: LoadedEngine?
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
        let isPrivate: Bool

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

    /// Fired synchronously at the top of `startRecording` (past the duplicate
    /// -start guard), before any engine work — the meeting recorder and
    /// `DictationCenter` share one physical engine slot, so this is how a
    /// meeting capture claims it ahead of time (wired to
    /// `DictationCenter.meetingCaptureWillStart()` in `AppState`).
    var captureWillStart: (() -> Void)?

    /// Wired by AppState to `DictationCenter.hasResidentEngine`: when the
    /// dictation engine is still resident after the `captureWillStart`
    /// handshake (a dictation mid-flight, draining its decode tail), the live
    /// pass parks like the busy-queue path and catches up on the recorder's
    /// buffered stream once `dictationEngineDidRelease()` fires — never two
    /// engines resident at once.
    var dictationEngineResident: (() -> Bool)?

    /// Wired by AppState (#744): a fresh engine load first awaits the model's
    /// download here, so a first recording shows its progress and a joined
    /// download is never started twice; the warm policy prewarms only a
    /// model already on disk. nil (tests) loads straight away.
    var modelProvisioner: TranscriptionModelProvisioner?

    /// Calendar event the active/last recording belongs to; `nil` for ad-hoc.
    private(set) var currentEventID: String?
    /// Title snapshot for the active/last recording.
    private(set) var currentTitle: String?
    /// The active capture saves private (MEETPRIV; `setCapturePrivate`).
    private(set) var currentPrivate = false

    /// Reads the voice registry for the post-diarization identification pass
    /// (samples, people, the event's invited set, the owner's people). Set by
    /// AppState once the shared DB opens; nil (no DB yet, tests) disables
    /// voice identification — clusters keep their "Speaker N" labels, the
    /// full degradation path. A read failure returns nil, which switches
    /// identification OFF for that recording (spec §2.6: no names, no queue,
    /// no auto samples, no notification) — never an empty snapshot, which
    /// would read as "nobody known" and queue every cluster as unknown.
    var registryLoader: (@Sendable (_ eventID: String?) async -> VoiceRegistrySnapshot?)?

    /// Persists a saved recording's registry outcome (label-queue tasks and
    /// self-trained samples) against its transcript id; returns the number
    /// of enqueued tasks. Set by AppState; failures are logged there and
    /// report 0 — never a failed save (spec §2.6).
    var registryWriter: (@Sendable (_ transcriptID: Int64, _ outcome: VoiceIdentificationOutcome) async -> Int)?

    /// Fired on the main actor whenever a job's phase changes (progress
    /// included, a failure as `.failed`), keyed by the job's audio file. The
    /// mobile hub feeds its `recording_job` progress from it; it observes
    /// every job, so a consumer filters by the audio URLs it ingested.
    var onJobPhase: ((_ audioURL: URL, _ phase: ProcessingJob.Phase) -> Void)?

    /// Fired on the main actor once a job's transcript is saved, with the
    /// transcript id the save returned. Same keying as `onJobPhase`.
    var onJobFinished: ((_ audioURL: URL, _ transcriptID: Int64) -> Void)?

    /// `.waiting` = a recording is capturing but something else still owns
    /// the engine slot (a batch job transcribing, the previous recording's draining tail,
    /// a resident dictation engine), so the live engine is deliberately not
    /// loaded yet.
    enum LiveEngineState: Equatable { case off, waiting, loading, running, unavailable }
    struct LiveChunk: Equatable, Identifiable { let id: Int; let text: String; let language: String }

    private(set) var liveEngineState: LiveEngineState = .off
    private(set) var liveChunks: [LiveChunk] = []

    /// Latest ~100 ms raw mic/system RMS pair from the active capture's
    /// recorder (`AudioRecording.liveLevels`), for the indicator's level
    /// meters. Zero whenever nothing is being captured.
    private(set) var captureLevels: CaptureLevels = .init(mic: 0, system: 0)

    /// Whether the owner muted their microphone in the active capture
    /// (`setMicMuted`). False whenever nothing is being captured: every
    /// capture starts unmuted.
    private(set) var micMuted = false

    /// Seconds into the active capture where the call audio went silent, once
    /// the silence has lasted `CallAudioWatch.minGapSec` after the call had
    /// been heard; nil otherwise and whenever nothing is being captured. The
    /// indicator warns on it — the tap may have dropped (an output-device
    /// switch), and the owner can still fix it during the call.
    private(set) var callAudioSilentSince: Double?

    /// Monotonic counter bumped once per transcript that lands in the database.
    /// Views that must refetch after a save observe THIS, never `phase`: with
    /// capture decoupled from the queue, `phase` never dips to `.idle` while
    /// another job is still queued or a failed one lingers, so a reload keyed
    /// on it silently misses the new row.
    private(set) var savedTick = 0

    // MARK: - Legacy single-slot projection

    /// Single-slot view of the state above, kept so the recorder UI that still
    /// renders one thing at a time (the recovered pill, the re-transcribe
    /// affordance) keeps working: capture wins, then the job the queue is
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
        if let message = newestFailedJob?.phase.failureMessage { return .failed(message) }
        if !jobs.isEmpty { return .transcribing(done: 0, total: 0) }
        return .idle
    }

    /// The failure the single-slot retry/dismiss pair works from: the newest
    /// one, so the user clears backwards from what just broke.
    private var newestFailedJob: ProcessingJob? {
        jobs.last { $0.phase.isFailed }
    }

    /// Legacy pointer at "the recording the retry/recovered pill acts on": the
    /// active capture, else an explicitly prepared/recovered recording, else the
    /// newest failure, else the job at the head of the queue.
    var pendingAudioURL: URL? {
        if case .recording = captureState { return captureAudioURL }
        if let entry = recoverable.first { return entry.audioURL }
        if let failed = newestFailedJob { return failed.audioURL }
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

    /// Anything at all in flight: capture, or a job the queue is working or
    /// still holds. A queued job counts — it will run without further input, so
    /// the single-slot `prepareRetry`/`retryTranscription` pair (and the
    /// affordances that drive it) must stay parked until the queue drains. A
    /// failed job does not: it needs the user, which is the whole point of
    /// retry.
    var isBusy: Bool { isCapturing || jobs.contains { !$0.phase.isFailed } }

    /// The failed job `retryTranscription` would actually re-run, or nil when
    /// it would do something else (a recovered recording takes precedence) or
    /// nothing at all (busy, no failure). Lets a pill disable a button rather
    /// than offer one that silently no-ops.
    var retriableFailureID: ProcessingJob.ID? {
        guard !isBusy, recoverable.isEmpty else { return nil }
        return newestFailedJob?.id
    }

    /// The failed job `dismissFailure` would actually drop. It needs the
    /// single-slot `phase` to read `.failed` (so nothing may be running) and
    /// clears a capture error ahead of any job.
    var dismissableFailureID: ProcessingJob.ID? {
        guard case .failed = phase, captureError == nil else { return nil }
        return newestFailedJob?.id
    }

    /// Whether `dismissFailure` would actually clear the `captureError` the
    /// capsule is showing. Mirrors that method's own guard — the capture-error
    /// branch is taken ahead of any failed job, so the only thing that can
    /// block it is a job the queue is actively working (which owns `phase`).
    /// Deliberately NOT `isBusy`: a merely queued job leaves the message's one
    /// action available.
    var captureErrorDismissable: Bool {
        guard captureError != nil, case .failed = phase else { return false }
        return true
    }

    /// `UserDefaults` keys of the pre-queue single-slot pointer. Read (and
    /// cleared) exactly once, by `restorePendingOnLaunch`, so a recording
    /// captured by an older build still recovers; nothing writes them any more —
    /// `rec_X.meta` sidecars replaced them.
    static let pendingAudioPathKey = "recorder.pendingAudioPath"
    static let pendingEventIDKey = "recorder.pendingEventID"
    static let pendingTitleKey = "recorder.pendingTitle"

    // MARK: - Internals

    /// Engine loaded at record-start for the live pass (with the key it was
    /// loaded for), handed to the recording's job on Stop so a single
    /// recording never loads it twice.
    private var loadedEngine: LoadedEngine?
    /// The running live transcription; its value is the final output, or nil when
    /// the live pass never ran or produced no usable text (→ batch fallback).
    /// Non-nil also means "the live pass holds the engine slot", which is what
    /// keeps a queued job from loading a second engine while the tail drains.
    private var liveTask: Task<TranscriptionOutput?, Never>?

    /// Consumer of the active recorder's `liveLevels` stream, feeding
    /// `captureLevels`. Per-capture like the recorder itself (never part of the
    /// engine-slot machinery): spawned when capture starts, torn down — with the
    /// levels reset to zero — on every path that ends capture.
    private var levelsTask: Task<Void, Never>?

    /// The `liveGeneration` pattern for the level feed: bumped on every
    /// capture start and teardown, captured by `startLevelsTask`'s loop, so a
    /// stale buffered level pair from a cancelled task (a value already
    /// delivered before the cancellation landed) can never clobber a new
    /// capture's meters — or the zero reset.
    private var levelsGeneration = 0

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

    /// Whether the active capture wants a live pass at all
    /// (`config.liveTranscription` snapshotted at start). False means Stop must
    /// neither await nor cancel `liveTask` — one still standing belongs to a
    /// PREVIOUS recording's draining tail, never to this capture. Readable so
    /// the indicator gates the live affordance on what THIS capture actually
    /// started with, not on a live Settings read a mid-recording toggle flips.
    private(set) var captureLiveEnabled = true

    /// The job the queue is currently working, whether or not it needs the
    /// engine; nil when the queue is parked. Readable so the indicator stack
    /// can promote the pill of the job that is genuinely being worked, rather
    /// than guessing from a phase (with diarization off a job can be active
    /// while its phase still reads `.queued`). Never an engine claim on its
    /// own — that is `engineJobID`.
    private(set) var activeJobID: ProcessingJob.ID?
    /// The active job while it holds the engine slot — a batch job, the only
    /// kind that transcribes, from its turn until its transcription is over
    /// (succeeded and the engine parked, or failed and the engine dropped).
    /// Nil for the rest of that job's run (role rendering, persist, save) and
    /// throughout a job that works from text it already has (the live pass's
    /// output, or a transcript kept from an earlier run): neither uses
    /// Whisper, so neither may park a new recording's live pass. The
    /// live-pass gates (`startRecording`, `dictationEngineDidRelease`) read
    /// this, never `activeJobID`; the warm policy reads `activeJobID` (see
    /// `isEngineBusy`).
    private(set) var engineJobID: ProcessingJob.ID?
    /// Jobs handed to the queue that have not started yet, in enqueue order
    /// (stop order). The queue starts the first one that can start (see
    /// `nextStartableJob`), one job at a time.
    private var queuedJobIDs: [ProcessingJob.ID] = []
    /// Queued jobs whose own recording's live tail is still draining in
    /// `stopAndProcess`: their input (live text or batch) is not known yet,
    /// so they cannot start, whatever the slot says.
    private var jobsAwaitingLiveTail: Set<ProcessingJob.ID> = []
    /// Each queued job's input (`plannedInput`), worked out once — it reads
    /// the job's pending row on the main actor — and reused by every start
    /// decision and label refresh until what decides it changes: the live
    /// tail's handover, or a retry re-queueing the job. Dropped when the job
    /// starts.
    @ObservationIgnored private var plannedInputs: [ProcessingJob.ID: JobInput] = [:]
    /// Job tasks parked in `awaitTurn`, resumed whenever something that
    /// decides which job may start changes: the queue's active job finished,
    /// a capture started or ended, a live pass let go of the engine.
    private var queueWaiters: [CheckedContinuation<Void, Never>] = []
    /// Queued batch jobs that wait only because a recording is capturing (the
    /// live pass owns the engine slot), as of the last time the queue looked.
    /// The indicator labels them "Waiting for the recording to stop" rather
    /// than a bare "Queued" that reads as stuck.
    private(set) var jobsWaitingForCapture: Set<ProcessingJob.ID> = []

    // MARK: - Warm engine slot

    /// `@AppStorage("transcription.preloadBeforeMeetings")` in Settings;
    /// absent = true. Gates the warm slot as a whole: parking after a job and
    /// prewarming ahead of meetings. Read fresh each poll tick (and each park),
    /// never snapshotted — flipping it off drains the slot on the next tick.
    static let preloadBeforeMeetingsKey = "transcription.preloadBeforeMeetings"

    /// The idle engine parked between recordings (the single-engine
    /// invariant's fourth holder — see the class doc). Filled by a finished
    /// job or a prewarm; emptied by `takeWarmOrLoad` (taken by a recording)
    /// or the warm-policy poll (unloaded).
    private var warmTranscriber: Transcriber?
    /// The provider+model identity (`engineKey()`) the warm engine was loaded
    /// for. A mismatch at take/poll time means Settings changed since it was
    /// parked — the stale engine is dropped, never handed to a recording.
    private var warmKey: String?
    /// The in-flight pre-load, when the poll decided to warm up ahead of a
    /// meeting. `takeWarmOrLoad` awaits it before looking at the slot, which
    /// is what makes a recording started mid-prewarm reuse that load instead
    /// of starting a second one.
    private var prewarmTask: Task<Void, Never>?
    /// The 30-second warm-policy poll loop (`startWarmPolicy`).
    private var warmPolicyTask: Task<Void, Never>?

    /// Warm-slot observability for tests and diagnostics; the slot itself
    /// stays private so nothing outside `takeWarmOrLoad`/the poll can move
    /// the engine.
    var isEngineWarm: Bool { warmTranscriber != nil }
    var isPrewarming: Bool { prewarmTask != nil }

    /// Test seam into the handover gap (see `isEngineBusy`): fires once per
    /// stop that owned the live pass, in the same main-actor step in which
    /// `stopAndProcess` hands the live engine (nil if its load failed) on — to
    /// a recording parked on the tail, else to the job — and releases the
    /// live slot — after both, and before the job's own task can claim
    /// `activeJobID`. Lets a test tick the warm policy exactly
    /// there instead of racing the scheduler to observe the gap. Nil in
    /// production.
    @ObservationIgnored var onLiveEngineHandedOnForTesting: (() -> Void)?

    /// Test seam into the queue: fires in the same main-actor step in which a
    /// job starts its turn (`awaitTurn` — claiming the engine slot too when
    /// its path needs one), before it runs. Lets a test prove a job did NOT
    /// start before some event — which no amount of waiting can — by
    /// recording what had happened at that moment. Nil in production.
    @ObservationIgnored var onJobTurnStartedForTesting: (() -> Void)?

    /// Latched synchronously at the top of `startRecording`, before its first
    /// suspension point (`recorder.start`), and cleared when the start attempt
    /// resolves either way. Without it, two rapid start triggers (the Record
    /// button plus two Join surfaces share one Center) could both pass the
    /// `isCapturing` check-then-act across that suspension and double-start,
    /// orphaning the first recorder as unstoppable capture.
    private var isStarting = false

    /// Audio file of the active capture.
    private var captureAudioURL: URL?

    /// Where recordings not yet saved are recorded (`pending_transcripts`);
    /// nil until the database opens (AppState sets it, then calls
    /// `restorePendingOnLaunch` again). A recording started without it is
    /// still captured and comes back from its audio file alone.
    var pendingStore: PendingTranscriptStore?
    /// The legacy `rec_*` sidecars were imported into `pendingStore`.
    private var legacySidecarsImported = false
    /// When this center was made (this launch): audio modified since is never
    /// taken for an older build's dismissed recording.
    let launchedAt: Date

    private let recorderFactory: () -> AudioRecording
    private let engineFactory: (TranscriptionConfig) async throws -> Transcriber
    private let diarizerFactory: (TranscriptionConfig) async throws -> SpeakerDiarizing
    private let decode: (URL) throws -> [Float]
    private let runnerResolver: () -> CLIRunnerProtocol?
    private let notifier: MeetingTranscriptNotifying
    let defaults: UserDefaults
    /// Directory the recorder writes `rec_*` files into and `restorePendingOnLaunch`
    /// scans. Injectable so tests neither write to nor scan the user's real one.
    let recordingsDirectory: URL
    /// Identity of the engine `engineFactory` would load right now (provider +
    /// model, the same Settings keys `defaultEngineFactory` reads). Consulted
    /// when parking and when taking from the warm slot, so a Settings change
    /// between the two invalidates the parked engine instead of serving it.
    private let engineKey: () -> String
    /// Injectable clock (the MeetingReminderCenter convention) for the
    /// warm-policy poll and for the timestamp that names an ingested phone
    /// recording (`ingestPhoneRecording`).
    let clock: () -> Date
    /// Reads the meeting window the warm policy decides against. The default
    /// stub sees no meetings (the Center is constructed before the DB pool
    /// exists); AppState hands in the real GRDB-backed provider via
    /// `configureWarmPolicy` once the pool opens.
    private var meetingsProvider: (Date) -> WarmMeetingWindow

    /// Recorder for the active recording; released once `stop()` is called.
    private var recorder: AudioRecording?

    /// `decode` is injectable for the same reason as `recorderFactory`/
    /// `engineFactory`: `AudioFileDecoder.decodePCM16k` drives `AVAudioConverter`,
    /// which cannot run under `swift test` (headless CoreAudio), so tests feed
    /// samples directly instead of a real audio file.
    ///
    /// `pendingStore` is nil in the app until the pool opens (AppState sets
    /// it); tests hand one in.
    ///
    /// `runnerResolver` is consulted only at the save step — stopping capture,
    /// finalizing the audio file, and transcribing must never depend on the
    /// `watchtower` CLI being locatable; a nil resolution fails visibly with
    /// the audio (and persisted transcript) kept for retry.
    init(
        pendingStore: PendingTranscriptStore? = nil,
        recorderFactory: @escaping () -> AudioRecording = { SystemAudioRecorder() },
        engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber = MeetingRecorderCenter.defaultEngineFactory,
        diarizerFactory: @escaping (TranscriptionConfig) async throws -> SpeakerDiarizing = {
            try await FluidAudioDiarizer.load(clusteringThreshold: $0.diarizationThreshold)
        },
        decode: @escaping (URL) throws -> [Float] = AudioFileDecoder.decodePCM16k(url:),
        runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
        notifier: MeetingTranscriptNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL = MeetingRecorderCenter.defaultRecordingsDirectory(),
        engineKey: @escaping () -> String = MeetingRecorderCenter.defaultEngineKey,
        now: @escaping () -> Date = Date.init,
        meetingsProvider: @escaping (Date) -> WarmMeetingWindow = { _ in .noMeetings }
    ) {
        self.pendingStore = pendingStore
        self.recorderFactory = recorderFactory
        self.engineFactory = engineFactory
        self.diarizerFactory = diarizerFactory
        self.decode = decode
        self.runnerResolver = runnerResolver
        self.notifier = notifier
        self.defaults = defaults
        self.recordingsDirectory = recordingsDirectory
        self.engineKey = engineKey
        self.clock = now
        self.launchedAt = now()
        self.meetingsProvider = meetingsProvider
        recordLegacyAudioCutoff()
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
        let (providerID, model) = resolveProviderAndModel()
        let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
        return try await provider.makeTranscriber(model: model) { _ in }
    }

    /// Production engine identity: the same two Settings keys (and defaults)
    /// `defaultEngineFactory` resolves, so "key matches" means "the factory
    /// would load exactly what is parked". `nonisolated` so it can serve as
    /// the init's default argument (evaluated outside the main actor); it
    /// only reads `UserDefaults.standard` — deliberately, like the factory,
    /// NOT the injected `defaults` (provider/model are `@AppStorage` keys).
    nonisolated static func defaultEngineKey() -> String {
        let (providerID, model) = resolveProviderAndModel()
        return "\(providerID)|\(model)"
    }

    /// The Settings selection both of the above read. Shared so the identity
    /// and the load can never drift apart — a default changed in one place
    /// only would silently make every key mismatch (or, worse, match an
    /// engine the factory never loaded).
    nonisolated private static func resolveProviderAndModel() -> (providerID: String, model: String) {
        (UserDefaults.standard.string(forKey: "transcription.provider") ?? "whisperkit",
         UserDefaults.standard.string(forKey: "transcription.model") ?? "large-v3-v20240930")
    }

    // MARK: - Warm engine policy

    /// Preload toggle, absent = true (the `remindersEnabledKey` convention).
    private var preloadEnabled: Bool {
        defaults.object(forKey: Self.preloadBeforeMeetingsKey) == nil
            || defaults.bool(forKey: Self.preloadBeforeMeetingsKey)
    }

    /// Whether anything but the warm slot holds (or is about to hold) the
    /// engine: a capture, a live pass still draining, a running job, or a job
    /// that has been handed an engine and not parked or used it yet. The
    /// policy never prewarms — and never unloads — while this is true. Its
    /// only reader is `warmPolicyTick`.
    ///
    /// A running job counts whether or not it holds the engine slot
    /// (`activeJobID`, not `engineJobID`): a job working from live text parks
    /// its handed-over engine when it starts and then renders roles for a
    /// while, and unloading the engine there would make a batch job queued
    /// right behind it — or the next recording — load it again. That is the
    /// warm policy's notion of busy only; the live-pass gates still read
    /// `engineJobID`, so such a job never parks a recording's live pass.
    ///
    /// That last term is not redundant: `stopAndProcess` hands the engine to
    /// the job and releases the live slot in one main-actor step, while the
    /// job's own task starts in a later one — and may wait longer still behind
    /// the job the queue is working. Without it a tick landing in between
    /// would see a free engine and prewarm a second model alongside the one
    /// the job is holding.
    private var isEngineBusy: Bool {
        isCapturing || liveTask != nil || activeJobID != nil || jobs.contains { $0.engine != nil }
    }

    /// The single engine-acquisition point for both load sites
    /// (`startLivePass` and the batch fallback in `transcribeAndSave`):
    /// (1) an in-flight prewarm is awaited first, so a recording started
    /// mid-prewarm reuses that load rather than starting a second one;
    /// (2) with the slot empty, an engine a stopped recording handed to its
    /// still-queued job (`ProcessingJob.engine`) is taken over instead — that
    /// job is not using it yet (it parks it, or loads again when its turn
    /// comes), and loading here would put a second model beside it. A live
    /// pass starting while the previous recording's job waits for the queue
    /// is the case this exists for;
    /// (3) a parked engine whose key still matches Settings is taken (the
    /// slot is emptied — the engine now belongs to the caller); a key
    /// mismatch drops the stale engine instead of serving it;
    /// (4) otherwise the factory loads fresh, under the key read BEFORE the
    /// load — the caller carries that key onward, so the engine is parked as
    /// what it is rather than as whatever Settings say when it finishes.
    ///
    /// Step (1) awaits the prewarm even when Settings changed while it was
    /// loading, and that is deliberate: an engine load is not cancellable, so
    /// skipping the await would leave the arriving prewarm in memory next to
    /// the one loaded here. The single-engine invariant outranks the stall a
    /// switch-then-instantly-record costs.
    private func takeWarmOrLoad(_ config: TranscriptionConfig) async throws -> LoadedEngine {
        if let prewarmTask {
            await prewarmTask.value
        }
        if warmTranscriber == nil, let holder = jobs.first(where: { $0.engine != nil }),
           let handed = holder.engine {
            updateJob(holder.id) { $0.engine = nil }
            warmTranscriber = handed.transcriber
            warmKey = handed.key
        }
        if let warm = warmTranscriber {
            let parkedKey = warmKey
            warmTranscriber = nil
            warmKey = nil
            if let parkedKey, parkedKey == engineKey() {
                return LoadedEngine(transcriber: warm, key: parkedKey)
            }
            // Stale: Settings switched provider/model since it was parked.
            // Fall through to load what the user actually selected now.
        }
        let key = engineKey()
        if let modelKey = TranscriptionModelProvisioner.ModelKey(id: key) {
            try await modelProvisioner?.prepare(modelKey, purpose: .meetings)
        }
        return LoadedEngine(transcriber: try await engineFactory(config), key: key)
    }

    /// Whether the model a load would use is confirmed on disk. True without
    /// a provisioner (tests) or for a key that names no provider model.
    private func modelOnDisk() -> Bool {
        guard let modelProvisioner, let modelKey = TranscriptionModelProvisioner.ModelKey(id: engineKey()) else {
            return true
        }
        return modelProvisioner.isDownloaded(modelKey)
    }

    /// Parks a finished job's engine back into the warm slot so the next
    /// recording skips the load — under the key it was LOADED for, never a
    /// freshly read one. With preloading off the engine is dropped right here
    /// instead — the slot must not keep a model in memory the user asked not
    /// to keep (and the poll, the other unload point, may not even be
    /// running), which also covers a toggle flipped off during a long load.
    /// Never called on a failure path: an engine that just failed is dropped
    /// by `failJob`, not parked.
    private func parkTranscriber(_ engine: LoadedEngine) {
        guard preloadEnabled else { return }
        warmTranscriber = engine.transcriber
        warmKey = engine.key
    }

    /// Starts the 30-second warm-policy poll (the `MeetingReminderCenter.start`
    /// shape). Called by AppState once the meetings provider is wired.
    func startWarmPolicy() {
        warmPolicyTask?.cancel()
        warmPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.warmPolicyTick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopWarmPolicy() {
        warmPolicyTask?.cancel()
        warmPolicyTask = nil
    }

    /// Late wiring for the warm policy's calendar read: the Center is created
    /// before the DB pool exists (the `registryLoader` precedent), so
    /// AppState hands the GRDB-backed provider in here once the pool opens.
    func configureWarmPolicy(meetingsProvider: @escaping (Date) -> WarmMeetingWindow) {
        self.meetingsProvider = meetingsProvider
    }

    /// One warm-policy decision tick — called every 30 s by the poll loop and
    /// directly from tests (the `MeetingReminderCenter.poll` convention). All
    /// judgment lives in `WarmEnginePolicy.decide`; this only gathers inputs
    /// (toggle and key read fresh each tick, never snapshotted) and applies
    /// the verdict.
    func warmPolicyTick(config: TranscriptionConfig = .fromDefaults()) {
        let now = clock()
        let decision = WarmEnginePolicy.decide(
            toggleEnabled: preloadEnabled,
            engineBusy: isEngineBusy,
            warmPresent: warmTranscriber != nil,
            prewarmInFlight: prewarmTask != nil,
            keyMatches: warmKey == engineKey(),
            modelOnDisk: modelOnDisk(),
            window: meetingsProvider(now),
            now: now
        )
        switch decision {
        case .prewarm:
            startPrewarm(config: config)
        case .unload:
            warmTranscriber = nil
            warmKey = nil
        case .none:
            break
        }
    }

    /// Loads the engine ahead of a meeting and parks it. Failure is silent by
    /// contract (logged only): a failed prewarm must never surface an error —
    /// the record-time load path reports errors as today, and the next tick
    /// may simply retry. The key is captured at start so the parked engine is
    /// labeled with what the factory was asked to load, even if Settings
    /// change mid-load; parking goes through `parkTranscriber` so a toggle
    /// switched off during the (long) load drops the arriving engine instead
    /// of stocking the slot the user just asked to keep empty.
    private func startPrewarm(config: TranscriptionConfig) {
        let key = engineKey()
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let transcriber = try await self.engineFactory(config)
                self.parkTranscriber(LoadedEngine(transcriber: transcriber, key: key))
            } catch {
                print("[MeetingRecorder] prewarm failed (will retry on a later tick): "
                      + error.localizedDescription)
            }
            self.prewarmTask = nil
        }
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
    /// rendered labels plus their registry payload (nil when the diarizer
    /// produced none — non-FluidAudio engines — or roles were not rendered);
    /// the save persists them to `speakers_json`. `registry` is what the save
    /// persists into the voice registry afterwards (nil = registry off or
    /// nothing identified).
    private func renderRoles(
        jobID: ProcessingJob.ID,
        output: TranscriptionOutput,
        audioURL: URL,
        samples: [Float]?,
        config: TranscriptionConfig,
        eventID: String?
    ) async -> RenderedRoles {
        let plain = RenderedRoles(text: output.text, utterances: nil, speakers: nil, registry: nil)
        guard config.diarization, !output.segments.isEmpty else { return plain }
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
            let features = ClusterFeatures.compute(speakers: speakers, activity: activity)
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
            let identified = await identifyVoices(clusterEmbeddings: clusterEmbeddings, features: features,
                                                  eventID: eventID, config: config)
            let (voiceNames, ownerClusters) = Self.filterMegaClusters(
                voiceNames: identified.names, speakers: speakers, ownerClusters: identified.ownerClusters)
            let ownerVoiceAlike = identified.ownerVoiceAlike
            // The «Я» veto silently removing the label would look like mic
            // detection randomly stopped working — log it once, here (the
            // mega-cluster suppression precedent; RoleAssigner stays pure).
            if case let .vetoed(cluster, name) = RoleAssigner.detectSelf(
                speakers: speakers, activity: activity, voiceNames: voiceNames,
                ownerClusters: ownerClusters, ownerVoiceAlike: ownerVoiceAlike) {
                print("[MeetingRecorder] «Я» veto: mic-dominant cluster \(cluster) confidently "
                      + "matches \"\(name)\", not the owner — no «Я» in this transcript")
            }
            if let utterances = RoleAssigner.assign(
                segments: output.segments, speakers: speakers,
                activity: activity, voiceNames: voiceNames, ownerClusters: ownerClusters,
                ownerVoiceAlike: ownerVoiceAlike
            ) {
                // Key the persisted embeddings by the SAME labels the
                // transcript renders (clusterLabels is what assign used).
                // A cluster that won zero transcript utterances (e.g. it only
                // covered silence) is filtered out — its label matches nothing
                // in the transcript, and shipping it would make the Go save
                // drop it as an orphan.
                let labels = RoleAssigner.clusterLabels(
                    speakers: speakers, activity: activity,
                    voiceNames: voiceNames, ownerClusters: ownerClusters,
                    ownerVoiceAlike: ownerVoiceAlike)
                let usedLabels = Set(utterances.map(\.speaker))
                let shipped = clusterEmbeddings.filter { cluster, _ in
                    labels[cluster].map(usedLabels.contains) ?? false
                }
                let originalLabels = Self.originalLabels(labels: labels, speakers: speakers)
                let speakerEmbeddings = shipped
                    .compactMap { cluster, embedding -> SpeakerEmbedding? in
                        guard let label = labels[cluster] else { return nil }
                        return Self.registryEntry(
                            label: label, embedding: embedding, originalLabel: originalLabels[cluster],
                            features: features[cluster], decision: identified.decisions[cluster],
                            appliedName: voiceNames[cluster])
                    }
                    .sorted { $0.speaker < $1.speaker } // deterministic payload
                let registry = identified.snapshot.map { snapshot in
                    Self.registryOutcome(labels: labels, shipped: shipped, voiceNames: voiceNames,
                                         decisions: identified.decisions, features: features,
                                         originalLabels: originalLabels, snapshot: snapshot)
                }
                return RenderedRoles(text: TranscriptSegments.render(utterances), utterances: utterances,
                                     speakers: speakerEmbeddings.isEmpty ? nil : speakerEmbeddings,
                                     registry: registry)
            }
            // Roles undeterminable (diarizer found no speakers) — flag it like
            // the error path so the notification stays honest.
            print("[MeetingRecorder] diarization found no speakers, saving without labels")
            updateJob(jobID) { $0.rolesError = "no speakers detected" }
            return plain
        } catch {
            print("[MeetingRecorder] diarization failed, saving without speaker labels: \(error.localizedDescription)")
            updateJob(jobID) { $0.rolesError = error.localizedDescription }
            return plain
        }
    }

    // MARK: - Capture

    /// Starts a recording for `eventID` (nil = ad-hoc). No-op while a recording
    /// is already being captured; the processing queue never blocks a start.
    /// The `rec_X.meta` sidecar is written before capture starts, so a crash
    /// still leaves a recoverable, event-linked pointer. Private when
    /// `isPrivate` (Record Privately) or the Settings default says so.
    func startRecording(
        eventID: String?, title: String?, isPrivate: Bool = false, config: TranscriptionConfig = .fromDefaults()
    ) async {
        guard !isCapturing else { return }
        // Past the duplicate-start guard — a rejected start must not fire the
        // dictation handshake — but before any capture/engine work begins.
        captureWillStart?()
        // Close the check-then-act window across `recorder.start`: a second
        // start arriving while this one is suspended must see capture busy.
        isStarting = true
        defer {
            isStarting = false
            // The queue re-looks once the start resolves: a failed start has
            // to hand the engine slot back to a parked batch job, and a
            // successful one turns a queued batch job into one waiting for
            // this recording (its label).
            wakeQueueWaiters()
        }

        currentEventID = eventID
        currentTitle = title
        let isPrivate = isPrivate || config.privateByDefault
        currentPrivate = isPrivate

        let recorder = recorderFactory()
        self.recorder = recorder
        let store = pendingStore
        let url = Self.uniqueRecordingURL(in: recordingsDirectory) { Self.isReserved($0, in: store) }

        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            try await recorder.start(to: url)
            captureAudioURL = url
            captureState = .recording(startedAt: Date())
            captureError = nil
            startLevelsTask(recorder: recorder)
            captureLiveEnabled = config.liveTranscription
            if !config.liveTranscription {
                // Live pass disabled in Settings: capture only, the batch path
                // transcribes from the file after Stop. The generation bump
                // fences a previous recording's still-draining pass out of the
                // just-cleared list (the `startLivePass` precedent).
                liveGeneration += 1
                liveChunks = []
                liveEngineState = .off
            } else if engineJobID == nil, liveTask == nil, dictationEngineResident?() != true {
                startLivePass(recorder: recorder, config: config)
            } else {
                // A batch job still transcribing, the previous recording's
                // still-draining live tail, or a dictation engine not yet
                // dropped by the captureWillStart handshake owns the engine
                // slot (a job rendering roles or saving holds none — it never
                // parks this pass). The recorder's live stream
                // buffers unboundedly from second zero, so the live pass loads
                // its engine when the slot frees and catches up on the backlog.
                liveChunks = []
                liveEngineState = .waiting
                pendingLiveStart = PendingLiveStart(recorder: recorder, config: config)
            }
            // Once the capture runs and shows: a slow or failing write never
            // delays or stops it, and a crash before the row lands is
            // recovered from the audio file alone.
            await beginPending(eventID: eventID, title: title, isPrivate: isPrivate, for: url)
        } catch {
            // Start failed before any audio was captured: nothing to keep.
            self.recorder = nil
            captureAudioURL = nil
            (currentEventID, currentTitle, currentPrivate) = (nil, nil, false)
            await removePending(for: url)
            captureError = error.localizedDescription
            notifier.sendTranscriptFailedNotification(reason: error.localizedDescription)
        }
    }

    /// The indicator's lock on the capture: in memory and its pending row
    /// (`persistPrivate`). No-op when nothing is captured.
    func setCapturePrivate(_ isPrivate: Bool) async {
        guard case .recording = captureState, let url = captureAudioURL else { return }
        currentPrivate = isPrivate
        await persistPrivate(isPrivate, for: url)
    }

    /// The lock on a queued job, until its save starts (`canChangePrivate`).
    func setJobPrivate(_ id: ProcessingJob.ID, _ isPrivate: Bool) async {
        guard let job = job(id), job.canChangePrivate else { return }
        updateJob(id) { $0.isPrivate = isPrivate }
        await persistPrivate(isPrivate, for: job.audioURL)
    }

    /// Keeps the owner's microphone out of the active capture while `muted`
    /// (the call audio is still recorded). No-op when nothing is captured.
    func setMicMuted(_ muted: Bool) {
        guard case .recording = captureState, let recorder else { return }
        recorder.setMicMuted(muted)
        micMuted = muted
    }

    /// Mirrors the active recorder's throttled level pairs into
    /// `captureLevels`, zeroing them when the stream finishes on its own
    /// (`recorder.stop()`). A cancelled task skips the trailing reset — the
    /// teardown path that cancelled it already reset on its behalf, and a new
    /// capture's levels may have landed in between.
    private func startLevelsTask(recorder: AudioRecording) {
        levelsGeneration += 1
        let generation = levelsGeneration
        levelsTask = Task { @MainActor [weak self] in
            // The level stream is throttled to ~100 ms pairs — the bin size
            // the watch expects.
            var callAudio = CallAudioWatch()
            for await levels in recorder.liveLevels {
                guard let self, self.levelsGeneration == generation else { return }
                self.captureLevels = levels
                callAudio.add(system: levels.system)
                self.setCallAudioSilentSince(callAudio.openGap?.startSec)
            }
            guard !Task.isCancelled, let self, self.levelsGeneration == generation else { return }
            self.captureLevels = .init(mic: 0, system: 0)
            self.setCallAudioSilentSince(nil)
        }
    }

    /// The one writer of `callAudioSilentSince`. Written only on change (the
    /// level loop runs at ~10 Hz and every write would re-render the pill);
    /// a gap opening sends the notification, a gap closing — or the capture
    /// ending mid-gap — withdraws it.
    private func setCallAudioSilentSince(_ value: Double?) {
        guard callAudioSilentSince != value else { return }
        if callAudioSilentSince == nil {
            notifier.sendCallAudioSilentNotification()
        } else if value == nil {
            notifier.withdrawCallAudioSilentNotification()
        }
        callAudioSilentSince = value
    }

    /// Ends the level feed for a capture that is over: every path that clears
    /// `captureState` runs this so the meters never show a stale level (and
    /// no stale mute). The
    /// generation bump fences out a value the cancelled task had already
    /// received but not yet written.
    private func stopLevelsTask() {
        levelsGeneration += 1
        levelsTask?.cancel()
        levelsTask = nil
        captureLevels = .init(mic: 0, system: 0)
        micMuted = false
        setCallAudioSilentSince(nil)
    }

    /// Loads the transcriber and, when it supports live (`makeLiveSession`
    /// returns non-nil), runs its live session over the recorder's live
    /// samples. Never fails the recording: a load/stream failure — or a
    /// provider that simply does not support live — only sets
    /// `liveEngineState` to `.unavailable` and leaves the batch fallback to
    /// handle stop. The loaded transcriber is stashed either way so the
    /// recording's job reuses it instead of loading twice. `handed` is an
    /// engine the previous recording's drained tail passed straight on (its
    /// key already checked against Settings); otherwise `takeWarmOrLoad`.
    private func startLivePass(recorder: AudioRecording, config: TranscriptionConfig, handed: LoadedEngine? = nil) {
        liveChunks = []
        liveEngineState = .loading
        loadedEngine = nil
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
            let loaded: LoadedEngine
            do {
                if let handed {
                    loaded = handed
                } else {
                    // Warm-slot fast path: a parked (or currently prewarming)
                    // engine is taken instead of loading a second one.
                    loaded = try await self.takeWarmOrLoad(config)
                }
            } catch {
                // A failed model download is on screen already (its pill has
                // Retry); the batch pass at Stop tries the download again.
                print("[MeetingRecorder] live engine unavailable: " + error.localizedDescription)
                await MainActor.run { setState(.unavailable) }
                return nil
            }
            await MainActor.run {
                guard self.liveGeneration == generation else { return }
                self.loadedEngine = loaded
            }
            guard let liveSession = loaded.transcriber.makeLiveSession(config: config) else {
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

        // `currentPrivate` is read only after this await, in the same turn
        // that sets `captureState = .idle`: the indicator's lock stays live
        // (`setCapturePrivate`) for as long as Stop finalizes the file, so a
        // flip in that window must reach the job (MEETPRIV-01).
        let result: RecordingResult
        do {
            result = try await recorder.stop() // also finishes liveSamples
        } catch {
            let isPrivate = currentPrivate
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
            stopLevelsTask()
            liveEngineState = .off
            if consumeLivePassOwnership() {
                liveTask?.cancel()
                let orphan = liveTask
                liveGeneration += 1
                // Cancellation cannot interrupt an in-progress
                // `transcribeWindow`, so the engine the orphan is still
                // decoding through is not free yet. `liveTask` therefore stays
                // set until it has actually exited — it IS the engine-slot
                // claim both residency gates read (`nextStartableJob` and
                // `startRecording`'s live-pass branch), so keeping it means a
                // parked batch job and a NEW recording alike wait rather than loading
                // a second engine alongside the orphan. Clearing it (and the
                // transcriber it loaded, which belongs to nobody now) plus the
                // handoff all happen once the await returns. The failure itself
                // surfaces immediately either way — only the slot waits.
                Task { @MainActor [weak self] in
                    _ = await orphan?.value
                    guard let self else { return }
                    self.liveTask = nil
                    self.loadedEngine = nil
                    self.startPendingLivePass()
                    self.wakeQueueWaiters()
                }
            } else {
                wakeQueueWaiters()
            }
            // The audio captured so far stays on disk with its sidecar: surface
            // it as a failed job so Retry re-runs the batch path from the file.
            if let startedURL {
                var job = ProcessingJob(audioURL: startedURL, eventID: eventID, title: title, isPrivate: isPrivate)
                job.phase = .failed(error.localizedDescription)
                jobs.append(job)
            }
            notifier.sendTranscriptFailedNotification(reason: error.localizedDescription)
            return
        }

        let isPrivate = currentPrivate
        captureState = .idle
        captureAudioURL = nil
        stopLevelsTask()
        let ownsLivePass = consumeLivePassOwnership()
        liveEngineState = .off

        // Enqueued — and given its place in the queue — before the live tail is
        // drained, so the queue order is stop order and the legacy `phase` never
        // dips through `.idle` mid-run. Marked as awaiting its tail until the
        // handover below, which is what guarantees the job starts only once it
        // is fully built — with the live text it may not need the engine for.
        let job = ProcessingJob(audioURL: result.audioURL, eventID: eventID, title: title, isPrivate: isPrivate)
        jobs.append(job)
        if ownsLivePass { jobsAwaitingLiveTail.insert(job.id) }
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
            // The engine the live pass loaded (with the key it was loaded
            // for) goes straight to a recording parked on this tail, so that
            // recording's live pass neither loads a second one nor depends on
            // running before this job does. Otherwise the job carries it, so
            // a batch fallback reuses it instead of loading again — a job
            // with live text parks it once it starts, unless a later
            // recording's live pass takes it over first (`takeWarmOrLoad`).
            // A stale engine (Settings switched provider/model since the
            // load) never reaches a new pass: the job carries it, and the warm
            // slot drops it as stale.
            let liveEngine = loadedEngine
            jobsAwaitingLiveTail.remove(job.id)
            plannedInputs[job.id] = nil // the live text (if any) decides it now
            let current = liveEngine.flatMap { $0.key == engineKey() ? $0 : nil }
            if !releaseLiveEngineSlot(handing: current) {
                updateJob(job.id) { $0.engine = liveEngine }
            }
            onLiveEngineHandedOnForTesting?()
        } else {
            // Capture ended, but the previous recording's tail still holds the
            // engine; wake the queue anyway so it re-checks.
            wakeQueueWaiters()
        }

        await task.value
    }

    /// Whether the recording being stopped is the one that actually holds the
    /// live pass, clearing the parked start either way (this recorder is
    /// finished). One still `.waiting` for the engine slot has no live output,
    /// and the `liveTask` standing at that point belongs to the PREVIOUS
    /// recording, whose own Stop owns it — never this job. A capture that
    /// disabled the live pass never owns one either.
    private func consumeLivePassOwnership() -> Bool {
        let owns = captureLiveEnabled && pendingLiveStart == nil
        pendingLiveStart = nil
        return owns
    }

    /// Releases the engine slot a finished capture's live pass held and hands it
    /// on: to a recording that started while the tail was draining (with
    /// `engine`, when given), otherwise to whatever the queue has parked.
    /// Split from clearing `captureState`, which happens the moment Stop is
    /// pressed — a new recording may start immediately, while the engine
    /// stays claimed until the tail has drained. Returns whether a live pass
    /// took `engine`; false leaves it with the caller.
    private func releaseLiveEngineSlot(handing engine: LoadedEngine?) -> Bool {
        liveTask = nil
        loadedEngine = nil
        liveGeneration += 1
        let started = startPendingLivePass(handing: engine)
        wakeQueueWaiters()
        return engine != nil && started
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
            let job = ProcessingJob(audioURL: entry.audioURL, eventID: entry.eventID, title: entry.title, isPrivate: entry.isPrivate)
            jobs.append(job)
            await startJobTask(jobID: job.id, config: config).value
            return
        }
        guard let failed = newestFailedJob else { return }
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
    /// `isPrivate`: a private recording's re-transcription saves private too.
    func prepareRetry(audioURL: URL, eventID: String?, title: String?, isPrivate: Bool) async {
        guard !isBusy else { return }
        do {
            try await pendingStore?.clearTranscript(recording: audioURL.lastPathComponent)
        } catch {
            print("[MeetingRecorder] could not clear the kept transcript of \(audioURL.lastPathComponent): "
                  + error.localizedDescription)
        }
        addRecoverable(RecoverableRecording(audioURL: audioURL, eventID: eventID, title: title, isPrivate: isPrivate),
                       atHead: true)
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
        addRecoverable(RecoverableRecording(audioURL: job.audioURL, eventID: job.eventID, title: job.title, isPrivate: job.isPrivate))
    }

    /// Forgets a recovered recording the user chose not to transcribe: drops the
    /// entry and marks its row dismissed so the "recovered" pill goes away for
    /// good — this session and on relaunch. The audio file is left on disk; the
    /// Go orphan sweep reclaims it like any other `rec_*` file, and the first
    /// launch after that removes the tombstone (`prunePendingRows`). Only acts on the idle recovered state,
    /// never mid-capture.
    func dismissRecovered() async {
        guard case .idle = captureState, !recoverable.isEmpty else { return }
        let entry = recoverable.removeFirst()
        do {
            try await pendingStore?.dismiss(recording: entry.audioURL.lastPathComponent, at: clock())
        } catch {
            print("[MeetingRecorder] could not mark \(entry.audioURL.lastPathComponent) dismissed: "
                  + error.localizedDescription)
        }
    }

    /// Recovers every recording captured before a crash, once the database is
    /// open (`pendingStore`; without it this does nothing, and AppState calls
    /// it again when the pool opens): each `pending_transcripts` row whose
    /// `rec_*` audio is still in the recordings directory, plus every `rec_*` `.caf`/`.m4a` with no row and no
    /// saved transcript — a recording started before the database opened
    /// (Review Focus 3), recovered without its event link. The legacy `rec_*`
    /// sidecars are imported into rows first (`LegacyRecordingSidecarImport`),
    /// and the three legacy `UserDefaults` keys of the pre-queue single-slot
    /// pointer are read — and cleared — once, so recordings captured by older
    /// builds recover too. A recording this session is capturing or
    /// processing is never listed.
    func restorePendingOnLaunch() async {
        guard let store = pendingStore else { return }
        if !legacySidecarsImported {
            legacySidecarsImported = true
            await LegacyRecordingSidecarImport.importAll(in: recordingsDirectory, into: store)
        }
        await migrateLegacyPendingDefaults(into: store)
        let busy = Set(jobs.map(\.audioURL)).union(captureAudioURL.map { [$0] } ?? [])
        await tombstoneLegacyAudioOnce(store: store, busy: busy)
        await prunePendingRows(store: store, busy: busy)
        let fallback = TranscriptionConfig.fromDefaults(defaults).privateByDefault
        for entry in Self.recoverable(in: recordingsDirectory, store: store, unknownPrivate: fallback)
        where !busy.contains(entry.audioURL) {
            addRecoverable(entry)
        }
    }

    /// One-shot migration off the single-slot pointer. The legacy UserDefaults
    /// pointer was durable across launches, so the migrated recording must stay
    /// durable too: its row is written BEFORE the keys are cleared — quitting
    /// without acting on the recovered pill would otherwise leave the recording
    /// invisible to every later launch. A failed write keeps the legacy pointer
    /// for the next launch (the keys clear last).
    private func migrateLegacyPendingDefaults(into store: PendingTranscriptStore) async {
        guard let path = defaults.string(forKey: Self.pendingAudioPathKey) else { return }
        let eventID = defaults.string(forKey: Self.pendingEventIDKey)
        let title = defaults.string(forKey: Self.pendingTitleKey)
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            do {
                try await store.begin(recording: url.lastPathComponent, eventID: eventID, title: title, at: clock())
            } catch {
                print("[MeetingRecorder] could not record the legacy pending recording: \(error.localizedDescription)")
                return
            }
            addRecoverable(RecoverableRecording(audioURL: url, eventID: eventID, title: title, isPrivate: false))
        }
        defaults.removeObject(forKey: Self.pendingAudioPathKey)
        defaults.removeObject(forKey: Self.pendingEventIDKey)
        defaults.removeObject(forKey: Self.pendingTitleKey)
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

    /// What a started job works from, decided by the queue in the step that
    /// starts it — so the path `runJob` takes is exactly the one the
    /// engine-slot check allowed, never re-derived from a second read.
    private enum JobInput {
        /// A transcript kept by a run whose save failed: re-save only.
        case persisted(PersistedTranscript)
        /// The recording's live pass produced the text: roles + save.
        case live(TranscriptionOutput, durationSec: Int)
        /// Decode the file and transcribe it — the one path that needs the
        /// engine slot.
        case batch

        var needsEngine: Bool {
            if case .batch = self { return true }
            return false
        }
    }

    /// Enqueues the job (`queuedJobIDs`, enqueue order) and spawns its task,
    /// which waits for its turn (`awaitTurn`) and then runs it.
    ///
    /// The queue is strictly serial — one job at a time, so saves, role
    /// rendering and voice-registry writes of two recordings never interleave
    /// (a second job's registry read could otherwise miss the samples the
    /// first one is about to write) — but not strictly FIFO: the next job to
    /// start is the OLDEST one that can start now. A job with its text in hand
    /// can always start; a batch job only when no capture or live pass owns
    /// the engine slot. So a batch job parked behind a running meeting never
    /// holds up the live-text jobs queued after it, and it still goes ahead of
    /// every later batch job once the meeting stops.
    private func startJobTask(jobID: ProcessingJob.ID, config: TranscriptionConfig) -> Task<Void, Never> {
        queuedJobIDs.append(jobID)
        plannedInputs[jobID] = nil // a retry's earlier run may have kept a transcript
        refreshJobsWaitingForCapture()
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let input = await self.awaitTurn(for: jobID)
            await self.runJob(jobID: jobID, input: input, config: config)
        }
    }

    /// Parks until this job is the one `nextStartableJob` picks while no job is
    /// active, then claims the turn — and the engine slot when its input needs
    /// it. Claiming happens in the same main-actor step as the final check, so
    /// a `startRecording` racing this cannot also load a live engine. Returns
    /// nil for a job dismissed while queued (it then ends at once).
    private func awaitTurn(for jobID: ProcessingJob.ID) async -> JobInput? {
        while true {
            if activeJobID == nil, let next = nextStartableJob(), next.id == jobID {
                queuedJobIDs.removeAll { $0 == jobID }
                plannedInputs[jobID] = nil
                activeJobID = jobID
                if next.input?.needsEngine == true { engineJobID = jobID }
                refreshJobsWaitingForCapture()
                onJobTurnStartedForTesting?()
                return next.input
            }
            await withCheckedContinuation { queueWaiters.append($0) }
        }
    }

    /// The oldest queued job that can start now, with the input it would run
    /// on: past the ones still awaiting their own live tail, and past batch
    /// jobs while a capture or a draining live pass owns the engine slot. Nil
    /// when nothing can start.
    private func nextStartableJob() -> (id: ProcessingJob.ID, input: JobInput?)? {
        let engineSlotFree = !isCapturing && liveTask == nil
        for id in queuedJobIDs where !jobsAwaitingLiveTail.contains(id) {
            // A queued job no longer in `jobs` starts at once with no input
            // and ends (`runJob`). Nothing removes a queued job today; a
            // future removal must wake the queue (`wakeQueueWaiters`) so its
            // task gets here instead of waiting for an unrelated wake.
            guard let job = job(id) else { return (id, nil) }
            let input = plannedInput(for: job)
            if engineSlotFree || !input.needsEngine { return (id, input) }
        }
        return nil
    }

    /// The input a job would run on if it started now, cached in
    /// `plannedInputs`. A kept transcript wins over live text, as it always
    /// has: it carries the roles of a run that already diarized.
    private func plannedInput(for job: ProcessingJob) -> JobInput {
        if let cached = plannedInputs[job.id] { return cached }
        let input: JobInput
        if let persisted = loadPersistedTranscript(audioURL: job.audioURL) {
            input = .persisted(persisted)
        } else if let liveOutput = job.liveOutput {
            input = .live(liveOutput, durationSec: job.liveDurationSec)
        } else {
            input = .batch
        }
        plannedInputs[job.id] = input
        return input
    }

    /// Recomputes `jobsWaitingForCapture`: queued batch jobs while a recording
    /// is capturing. Written only on change — it drives the indicator.
    private func refreshJobsWaitingForCapture() {
        var waiting: Set<ProcessingJob.ID> = []
        if isCapturing {
            for id in queuedJobIDs where !jobsAwaitingLiveTail.contains(id) {
                if let job = job(id), plannedInput(for: job).needsEngine { waiting.insert(id) }
            }
        }
        if waiting != jobsWaitingForCapture { jobsWaitingForCapture = waiting }
    }

    /// Resumes every job parked in `awaitTurn` so it re-checks whether it may
    /// start. It releases nothing itself — the turn is owned by `activeJobID`
    /// and the engine slot by `isCapturing`/`liveTask`, and a woken job that
    /// still may not start parks again.
    private func wakeQueueWaiters() {
        refreshJobsWaitingForCapture()
        let waiters = queueWaiters
        queueWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// The dictation center dropped its resident engine (the other direction
    /// of the shared-slot handshake): start the live pass parked on it, unless
    /// a batch job or a draining live tail holds the slot — their own release
    /// paths already call `startPendingLivePass`.
    func dictationEngineDidRelease() {
        guard engineJobID == nil, liveTask == nil else { return }
        startPendingLivePass()
    }

    /// A recording whose live pass waited for the engine slot starts it now
    /// — on `engine` when one is handed over, else loading its own — and
    /// drains the samples buffered since second zero. Returns whether a pass
    /// was parked and started.
    @discardableResult
    private func startPendingLivePass(handing engine: LoadedEngine? = nil) -> Bool {
        guard case .recording = captureState, let pending = pendingLiveStart else { return false }
        pendingLiveStart = nil
        startLivePass(recorder: pending.recorder, config: pending.config, handed: engine)
        return true
    }

    private func runJob(jobID: ProcessingJob.ID, input: JobInput?, config: TranscriptionConfig) async {
        defer {
            // A batch job still holding the engine slot here never finished
            // its transcription (it failed, the engine dropped): release it
            // now — one that did released it already (`transcribeAndSave`).
            // Only a job that held the slot can have parked a live pass; one
            // that worked from text must not start a pass parked on something
            // else (a dictation engine still resident).
            releaseEngineSlot(of: jobID)
            activeJobID = nil
            wakeQueueWaiters()
        }
        guard let input, self.job(jobID) != nil else { return } // dismissed while queued

        switch input {
        case let .persisted(persisted):
            // A transcript persisted by a run whose save failed re-saves
            // directly: no decode, no transcription, no re-diarization (spec
            // §7). Its roles flag describes exactly that text, so it is NOT
            // reset here.
            await save(jobID: jobID,
                       text: persisted.text,
                       utterances: persisted.utterances,
                       speakers: persisted.speakers,
                       durationSec: persisted.durationSec,
                       langStats: persisted.langStats)
        case let .live(output, durationSec):
            updateJob(jobID) { $0.rolesError = nil } // per-run state, reset at the run boundary
            await renderAndSave(jobID: jobID, output: output, samples: nil,
                                durationSec: durationSec, config: config)
        case .batch:
            updateJob(jobID) { $0.rolesError = nil } // per-run state, reset at the run boundary
            await transcribeAndSave(jobID: jobID, config: config)
        }
    }

    /// Batch path: decode the file + run the windowed transcriber over it. Also
    /// the crash-recovery and retry path. The engine slot is released the
    /// moment the transcription is over, so a recording started during the
    /// (slow) role rendering and save runs its live pass on the engine just
    /// parked rather than waiting for the save.
    private func transcribeAndSave(jobID: ProcessingJob.ID, config: TranscriptionConfig) async {
        guard let transcribed = await transcribeBatch(jobID: jobID, config: config) else { return }
        releaseEngineSlot(of: jobID)
        await renderAndSave(jobID: jobID, output: transcribed.output, samples: transcribed.samples,
                            durationSec: transcribed.samples.count / TranscriptionConfig.sampleRate, config: config)
    }

    /// Lets go of the engine slot a batch job held through its transcription
    /// and starts a recording's live pass parked on it. The job keeps its
    /// turn (`activeJobID`); a job that never got this far (its transcription
    /// failed) is released by `runJob` instead.
    private func releaseEngineSlot(of jobID: ProcessingJob.ID) {
        guard engineJobID == jobID else { return }
        engineJobID = nil
        startPendingLivePass()
    }

    /// Decode + transcription of the batch path, nil once the job has failed.
    /// Its own function so the engine — the job's handed-over one, the parked
    /// one, or a fresh load — is referenced nowhere once it returns: parked
    /// (or dropped, with preloading off) before the slot is released, never
    /// kept alive beside the one a live pass may load next.
    private func transcribeBatch(jobID: ProcessingJob.ID,
                                 config: TranscriptionConfig) async -> (output: TranscriptionOutput, samples: [Float])? {
        guard let job = self.job(jobID) else { return nil }
        updateJob(jobID) { $0.phase = .transcribing(done: 0, total: 0) }

        // Consume the reusable engine (if the live pass handed one over) up
        // front, before any early-return path below — so an abandoned engine from
        // a failed attempt is never left around for a later retry to pick up.
        let reusableEngine = job.engine
        updateJob(jobID) { $0.engine = nil }

        let samples: [Float]
        do {
            samples = try decode(job.audioURL)
        } catch {
            failJob(jobID, error.localizedDescription)
            return nil
        }

        let engine: LoadedEngine
        if let reusableEngine {
            engine = reusableEngine
        } else {
            do {
                engine = try await takeWarmOrLoad(config)
            } catch {
                failJob(jobID, error.localizedDescription)
                return nil
            }
        }

        let output: TranscriptionOutput
        do {
            output = try await runTranscription(jobID: jobID, engine.transcriber, samples: samples, config: config)
        } catch {
            // A throwing engine is never parked — its retry loads fresh.
            failJob(jobID, error.localizedDescription)
            return nil
        }

        // Transcription succeeded and the engine has served this job — park it
        // warm for the next recording. The poll is the single unload point
        // (parkTranscriber itself drops it when preloading is off).
        parkTranscriber(engine)
        return (output, samples)
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
        // The transcription is done, so the handed-over live engine has served
        // its purpose — park it into the warm slot (or drop it, when preloading
        // is off) before the (slow) role rendering rather than pinning it on
        // the job for the rest of its life. The batch path already consumed it
        // in `transcribeAndSave`; this is the live path's release, and the job
        // must not keep a second reference to what the slot now owns. It sits
        // ABOVE the empty-text judgment for the same reason the batch path's
        // park does: a recording of silence says nothing about the engine's
        // health, so both paths keep it either way.
        if let handedOver = job.engine {
            parkTranscriber(handedOver)
        }
        updateJob(jobID) { $0.engine = nil }
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let audioURL = job.audioURL
            let message = await Task.detached { Self.noSpeechMessage(MicActivity.load(for: audioURL)) }.value
            failJob(jobID, message)
            return
        }
        let rendered = await renderRoles(jobID: jobID, output: output, audioURL: job.audioURL,
                                         samples: samples, config: config, eventID: job.eventID)
        // Keep the (role-tagged) transcript in the recording's row so a failed
        // save is retried from it instead of paying for a full
        // re-transcription — or a re-diarization (spec §7).
        await persistTranscript(text: rendered.text, utterances: rendered.utterances,
                                speakers: rendered.speakers, durationSec: durationSec,
                                langStats: output.langStats, audioURL: job.audioURL)
        await save(jobID: jobID, text: rendered.text, utterances: rendered.utterances,
                   speakers: rendered.speakers, durationSec: durationSec, langStats: output.langStats,
                   registry: rendered.registry, voiceNotifications: config.voiceNotifications)
    }

    /// Save step: the only place the `watchtower` CLI is needed. Resolves the
    /// runner here — never earlier — so a missing CLI still leaves the recording
    /// stopped, the audio finalized, and the transcript persisted for retry.
    /// `registry` (nil on the sidecar-retry path, which re-saves without
    /// re-diarizing) is persisted against the saved transcript id afterwards;
    /// it can never fail the save.
    private func save(jobID: ProcessingJob.ID,
                      text: String,
                      utterances: [TranscriptUtterance]?,
                      speakers: [SpeakerEmbedding]?,
                      durationSec: Int,
                      langStats: [String: Int],
                      registry: VoiceIdentificationOutcome? = nil,
                      voiceNotifications: Bool = true) async {
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
                langStatsJSON: Self.encodeLangStats(langStats),
                isPrivate: job.isPrivate
            )
            let rolesError = self.job(jobID)?.rolesError
            await removePending(for: job.audioURL)
            // A failed job pointing at the SAME audio goes with it: this
            // recording is persisted now, so retrying that one would save a
            // duplicate transcript of it.
            jobs.removeAll { $0.id == jobID || ($0.phase.isFailed && $0.audioURL == job.audioURL) }
            recoverable.removeAll { $0.audioURL == job.audioURL }
            savedTick += 1
            if !result.segmentsOK {
                // The CLI dropped the segments file (render mismatch = Go↔Swift
                // renderer drift, or a malformed payload). The transcript row is
                // saved either way; log so the drift is not invisible.
                print("[MeetingRecorder] CLI dropped segments: \(result.segmentsError ?? "unknown reason")")
            }
            let title = job.title ?? "Recording"
            // Recap/roles failures are non-fatal — the transcript row is saved;
            // flag them in the notification rather than reporting a failure.
            if job.isPrivate {
                // MEETPRIV-01: nothing was generated, on purpose.
                notifier.sendTranscriptReadyNotification(title: "\(title) — saved as private, no recap")
            } else if !result.recapOK {
                if result.recapSkipped {
                    notifier.sendTranscriptReadyNotification(
                        title: "\(title) — transcript saved (too short for recap)")
                } else {
                    notifier.sendTranscriptReadyNotification(
                        title: "\(title) — transcript saved, recap needs retry")
                }
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
            onJobFinished?(job.audioURL, result.transcriptID)
            await persistRegistry(registry, transcriptID: result.transcriptID, title: title,
                                  notify: voiceNotifications)
        } catch {
            failJob(jobID, error.localizedDescription)
        }
    }

    /// Hands the outcome to the writer after a successful save and notifies
    /// when voices were queued. Never fails the save: the writer logs and
    /// reports 0 on error.
    private func persistRegistry(
        _ outcome: VoiceIdentificationOutcome?,
        transcriptID: Int64,
        title: String,
        notify: Bool
    ) async {
        guard let outcome, !outcome.isEmpty, let registryWriter else { return }
        let queued = await registryWriter(transcriptID, outcome)
        if queued > 0 && notify {
            notifier.sendVoicesToLabelNotification(title: title, count: queued, transcriptID: transcriptID)
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
        let before = jobs[index].phase
        mutate(&jobs[index])
        let job = jobs[index]
        if job.phase != before {
            onJobPhase?(job.audioURL, job.phase)
        }
    }

    /// Why a recording yielded no text. A bare "No speech recognized" hid
    /// the usual cause: the call's audio never reached the recording (the
    /// activity sidecar's system channel is silent throughout or went
    /// silent and stayed so), leaving only a quiet room microphone.
    nonisolated static func noSpeechMessage(_ activity: MicActivity?) -> String {
        guard let activity else { return "No speech recognized" }
        var watch = CallAudioWatch(binSec: MicActivity.binDuration)
        activity.bins.forEach { watch.add(system: $0.sys) }
        if watch.neverHeardCall {
            return "No speech recognized — no call audio was captured at all. If this was a call, \(callAudioOutputHint)"
        }
        if let gap = watch.openGap {
            return "No speech recognized — call audio stopped at \(TranscriptFormatting.formatTimecode(gap.startSec)) "
                + "and never came back — \(callAudioOutputHint)"
        }
        return "No speech recognized"
    }

    /// Fails a job and fires the failure notification. The job stays in the
    /// queue (retriable, and never blocking what is behind it) and its audio
    /// file is intentionally left untouched. Any engine the job still carried is
    /// dropped: a failed job can sit here indefinitely, and its retry loads a
    /// fresh one anyway.
    private func failJob(_ id: ProcessingJob.ID, _ message: String) {
        updateJob(id) {
            $0.phase = .failed(message)
            $0.engine = nil
        }
        notifier.sendTranscriptFailedNotification(reason: message)
    }

    // MARK: - Pending rows (crash recovery)

    /// Records the recording as not saved yet. Best-effort, but logged: a
    /// recording whose row never landed still comes back after a crash from
    /// its audio file alone, only without its event link.
    private func beginPending(eventID: String?, title: String?, isPrivate: Bool, for audioURL: URL) async {
        guard let store = pendingStore else {
            print("[MeetingRecorder] the database is not open: \(audioURL.lastPathComponent) records without its "
                  + "pending row and is recovered from its audio file if the app quits before it is saved")
            return
        }
        do {
            try await store.begin(recording: audioURL.lastPathComponent, eventID: eventID, title: title,
                                  isPrivate: isPrivate, at: clock())
        } catch {
            print("[MeetingRecorder] failed to record \(audioURL.lastPathComponent) as pending: "
                  + "\(error.localizedDescription) — it is recovered from its audio file alone")
        }
    }

    /// A row left behind makes a saved recording look unsaved, so the failure
    /// is logged.
    private func removePending(for audioURL: URL) async {
        do {
            try await pendingStore?.remove(recording: audioURL.lastPathComponent)
        } catch {
            print("[MeetingRecorder] failed to remove the pending row of \(audioURL.lastPathComponent): "
                  + error.localizedDescription)
        }
    }

    /// The recordings to recover, oldest first: the rows (not dismissed) whose
    /// audio is still in `directory`, then — merged in name order — every
    /// `rec_*` audio file there with no row and no saved transcript (its
    /// private flag unknown: `unknownPrivate`, the Settings default).
    private static func recoverable(
        in directory: URL, store: PendingTranscriptStore, unknownPrivate: Bool
    ) -> [RecoverableRecording] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            print("[MeetingRecorder] cannot scan \(directory.path) for recoverable recordings: "
                  + "\(error.localizedDescription)")
            return []
        }
        let audio = Set(names.filter { $0.hasPrefix("rec_") && recordingAudioExtensions.contains(($0 as NSString).pathExtension) })
        let rows: [PendingTranscript]
        let saved: Set<String>
        do {
            rows = try store.pending()
            saved = try store.savedAudioPaths()
        } catch {
            print("[MeetingRecorder] cannot read the pending recordings: \(error.localizedDescription)")
            return []
        }
        var byName: [String: RecoverableRecording] = [:]
        var withRow: Set<String> = []
        for row in rows {
            withRow.insert(row.recording)
            // A row whose audio is gone (the daemon's orphan sweep took it)
            // is not listed; `prunePendingRows` removes it at launch.
            guard audio.contains(row.recording) else { continue }
            // A saved recording whose row a failed removal left behind.
            if row.dismissed || saved.contains(directory.appendingPathComponent(row.recording).path) { continue }
            byName[row.recording] = RecoverableRecording(audioURL: directory.appendingPathComponent(row.recording),
                                                         eventID: row.eventID, title: row.title, isPrivate: row.isPrivate)
        }
        for name in audio where !withRow.contains(name) {
            let url = directory.appendingPathComponent(name)
            if saved.contains(url.path) { continue }
            byName[name] = RecoverableRecording(audioURL: url, eventID: nil, title: nil, isPrivate: unknownPrivate)
        }
        return byName.keys.sorted { recoverySortKey($0) < recoverySortKey($1) }.compactMap { byName[$0] }
    }

    // MARK: - Transcript persistence (retry save without re-transcribing)

    /// Transcript + metadata kept in the recording's `pending_transcripts` row
    /// right after transcription succeeds, removed on a successful save. While
    /// a save failure stands, retry re-invokes save straight from the row
    /// instead of re-transcribing.
    private struct PersistedTranscript {
        let text: String
        let utterances: [TranscriptUtterance]?
        let speakers: [SpeakerEmbedding]?
        let durationSec: Int
        let langStats: [String: Int]
    }

    /// The row's `meta_json` beside the transcript text. `utterances`/`speakers`
    /// are optional so payloads written before the segments/speaker-identity
    /// work still decode (they retry as segment-less/embedding-less saves).
    /// Also the encoding of the legacy `rec_*.json` sidecar.
    struct PersistedTranscriptMeta: Codable {
        let durationSec: Int
        let langStats: [String: Int]
        var utterances: [TranscriptUtterance]?
        var speakers: [SpeakerEmbedding]?
    }

    /// Best-effort: a persistence failure only means a later save retry pays
    /// for a full re-transcription, so it is logged, not surfaced.
    private func persistTranscript(text: String,
                                   utterances: [TranscriptUtterance]?,
                                   speakers: [SpeakerEmbedding]?,
                                   durationSec: Int,
                                   langStats: [String: Int],
                                   audioURL: URL) async {
        guard let store = pendingStore else { return }
        let meta = PersistedTranscriptMeta(durationSec: durationSec, langStats: langStats,
                                           utterances: utterances, speakers: speakers)
        do {
            let json = String(bytes: try JSONEncoder().encode(meta), encoding: .utf8) ?? "{}"
            try await store.saveTranscript(recording: audioURL.lastPathComponent, text: text, metaJSON: json, at: clock())
        } catch {
            print("[MeetingRecorder] could not keep the transcript of \(audioURL.lastPathComponent) for a retry: "
                  + error.localizedDescription)
        }
    }

    /// Non-empty text and decodable metadata, or nil (then the retry
    /// re-transcribes).
    private func loadPersistedTranscript(audioURL: URL) -> PersistedTranscript? {
        let found: PendingTranscript?
        do {
            found = try pendingStore?.transcript(recording: audioURL.lastPathComponent)
        } catch {
            print("[MeetingRecorder] cannot read the kept transcript of \(audioURL.lastPathComponent), "
                  + "re-transcribing: \(error.localizedDescription)")
            return nil
        }
        guard let row = found,
              let text = row.transcript, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let json = row.metaJSON else {
            return nil
        }
        let meta: PersistedTranscriptMeta
        do {
            meta = try JSONDecoder().decode(PersistedTranscriptMeta.self, from: Data(json.utf8))
        } catch {
            print("[MeetingRecorder] the kept transcript of \(audioURL.lastPathComponent) has unreadable "
                  + "metadata, re-transcribing: \(error.localizedDescription)")
            return nil
        }
        return PersistedTranscript(text: text, utterances: meta.utterances, speakers: meta.speakers,
                                   durationSec: meta.durationSec, langStats: meta.langStats)
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

    // MARK: - Phone recording ingest (mobile hub)

    /// Ingests a recording made on the phone (AAC `.m4a`, mic only) and
    /// enqueues it for transcription straight away — a phone recording is
    /// transcribed automatically, so it never passes through the opt-in
    /// `recoverable` list. The job queues behind whatever runs and, like any
    /// job, never claims the engine while the Mac is capturing (the
    /// single-engine invariant). `eventID` links the transcript and scopes
    /// voice matching to the event's attendees.
    ///
    /// The name is reserved on the main actor, the same actor `startRecording`
    /// picks and reserves its `.caf` name on without suspending, so ingests and
    /// a Desktop capture of the same second never share a stem (the exclusive
    /// create also guards writers off this actor); only the copy runs off it.
    /// Returns the ingested audio URL — the key `onJobPhase`/`onJobFinished`
    /// report under — without awaiting the job. Throws when the source is not
    /// an audio recording (`PhoneIngestError.notAudio`) or cannot be read
    /// (`PhoneIngestError.unreadable`), or the reservation or the
    /// copy fails (nothing is enqueued and nothing is left behind).
    @discardableResult
    func ingestPhoneRecording(
        audioURL sourceURL: URL,
        eventID: String?,
        title: String?,
        config: TranscriptionConfig
    ) async throws -> URL {
        let isAudio = try await Task.detached { try await Self.isAudioRecording(sourceURL) }.value
        guard isAudio else { throw PhoneIngestError.notAudio }
        guard let store = pendingStore else { throw PhoneIngestError.databaseUnavailable }
        let isPrivate = config.privateByDefault // no per-recording choice on the phone
        let audioURL = try await Self.reservePhoneRecording(eventID: eventID, title: title, isPrivate: isPrivate,
                                                            in: recordingsDirectory, store: store, date: clock())
        try await Task.detached {
            try await Self.copyPhoneRecording(from: sourceURL, to: audioURL, store: store)
        }.value
        let job = ProcessingJob(audioURL: audioURL, eventID: eventID, title: title, isPrivate: isPrivate)
        jobs.append(job)
        _ = startJobTask(jobID: job.id, config: config)
        return audioURL
    }
}

extension MeetingRecorderCenter.ProcessingJob.Phase {
    var isFailed: Bool { failureMessage != nil }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
