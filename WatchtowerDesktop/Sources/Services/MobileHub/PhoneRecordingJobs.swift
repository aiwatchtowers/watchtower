import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The transcriber's job callbacks the tracker chains onto
/// (`MeetingRecorderCenter.onJobPhase` / `onJobFinished`, spec §6.4 step 4).
@MainActor
protocol PhoneRecordingJobEvents: AnyObject {
    var onJobPhase: ((_ audioURL: URL, _ phase: MeetingRecorderCenter.ProcessingJob.Phase) -> Void)? { get set }
    var onJobFinished: ((_ audioURL: URL, _ transcriptID: Int64) -> Void)? { get set }
}

extension MeetingRecorderCenter: PhoneRecordingJobEvents {}

/// The hub's side of a phone recording after the relay acked it (mobile POC
/// spec §6.4, §4.12): it hands the upload's audio to the transcriber, then
/// follows that job through the transcriber's callbacks into the sidecar's
/// `phone_recordings(upload_id, audio_path, transcript_id, …)`, which the
/// `recording_job` slice publishes and whose transcript ids feed the
/// `meeting_transcript` slice's `phone_recording_id`. Each change nudges the
/// publisher's fast lane (`recording_job`, plus `meeting_transcript` once a
/// transcript is linked).
///
/// Main-actor, like the transcriber. A hub companion: `start()` chains onto
/// the recorder's single-closure callbacks (the earlier closures still run)
/// and `stop()` hands them back; a rebuilt hub reloads the remembered jobs
/// from the sidecar, so it follows the jobs an earlier hub ingested.
@MainActor
final class PhoneRecordingJobs: HubCompanion {
    /// Lands the audio in the recordings directory and enqueues its job;
    /// returns the ingested file, the key the callbacks report under.
    /// Production: `MeetingRecorderCenter.ingestPhoneRecording`.
    typealias Enqueue = @MainActor (_ audio: URL, _ eventID: String?, _ title: String?) async throws -> URL

    private let sidecar: HubSyncState
    private let dbPool: DatabasePool
    private weak var events: (any PhoneRecordingJobEvents)?
    private let enqueue: Enqueue
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: Constants.bundleID, category: "PhoneRecordingJobs")
    private var onChange: (@Sendable (Set<SliceKind>) -> Void)?

    /// Audio path → the job, for every remembered upload.
    private var jobsByPath: [String: HubSyncState.PhoneRecordingJob] = [:]
    /// Transcript id → upload id, read off the main actor by the
    /// `meeting_transcript` slice.
    private let transcriptUploads = OSAllocatedUnfairLock<[Int64: String]>(initialState: [:])
    private var previousPhase: ((URL, MeetingRecorderCenter.ProcessingJob.Phase) -> Void)?
    private var previousFinished: ((URL, Int64) -> Void)?
    private(set) var isRunning = false

    init(
        sidecar: HubSyncState,
        dbPool: DatabasePool,
        events: (any PhoneRecordingJobEvents)?,
        now: @escaping @Sendable () -> Date = { Date() },
        enqueue: @escaping Enqueue
    ) throws {
        self.sidecar = sidecar
        self.dbPool = dbPool
        self.events = events
        self.now = now
        self.enqueue = enqueue
        let remembered = try sidecar.phoneRecordings()
        for job in remembered {
            jobsByPath[job.audioPath] = job
        }
        transcriptUploads.withLock { map in
            for job in remembered {
                if let transcriptID = job.transcriptID { map[transcriptID] = job.uploadID }
            }
        }
    }

    /// The app's tracker: phone recordings go through the transcriber's own
    /// phone ingest (`ingestPhoneRecording`, Settings' transcription config)
    /// and are followed through its job callbacks.
    static func live(sidecar: HubSyncState, dbPool: DatabasePool, recorder: MeetingRecorderCenter) throws -> PhoneRecordingJobs {
        try PhoneRecordingJobs(sidecar: sidecar, dbPool: dbPool, events: recorder) { [weak recorder] audio, eventID, title in
            guard let recorder else { throw CancellationError() }
            return try await recorder.ingestPhoneRecording(audioURL: audio, eventID: eventID, title: title, config: .fromDefaults())
        }
    }

    /// Where the fast-lane nudges go (the publisher's `nudge(kinds:)`); set
    /// once the publisher exists.
    func setOnChange(_ handler: (@Sendable (Set<SliceKind>) -> Void)?) {
        onChange = handler
    }

    /// The upload a transcript came from; nil for a Mac recording.
    nonisolated func uploadID(forTranscript transcriptID: Int64) -> String? {
        transcriptUploads.withLock { $0[transcriptID] }
    }

    // MARK: - Ingest

    /// Ingests one acked upload's audio: an `event_id` whose event no longer
    /// exists is dropped, so the transcript is saved ad-hoc instead of
    /// failing on the foreign key (review focus 4). The job is remembered as
    /// `queued` in the same main-actor turn as the enqueue's return, so its
    /// first callback always finds it. Throws when the event lookup or the
    /// ingest fails; nothing is remembered then.
    func ingest(_ upload: RecordingUploadPayload, audio: URL) async throws {
        let eventID = try await liveEventID(upload.eventID)
        let audioURL = try await enqueue(audio, eventID, upload.titleHint)
        save(HubSyncState.PhoneRecordingJob(
            uploadID: upload.id, audioPath: audioURL.path, status: .queued,
            percent: nil, transcriptID: nil, error: nil, updatedAt: now()
        ))
    }

    private func liveEventID(_ eventID: String?) async throws -> String? {
        guard let eventID, !eventID.isEmpty else { return nil }
        let exists = try await dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM calendar_events WHERE id = ?)", arguments: [eventID]) ?? false
        }
        guard exists else {
            logger.info("phone recording for a deleted event \(eventID, privacy: .public): ingested ad-hoc")
            return nil
        }
        return eventID
    }

    // MARK: - Job callbacks

    /// A job's phase changed. Jobs the hub did not ingest (the Mac's own
    /// recordings) and a phase after `done` are ignored.
    func phaseChanged(audioURL: URL, phase: MeetingRecorderCenter.ProcessingJob.Phase) {
        guard var job = jobsByPath[audioURL.path], job.status != .done else { return }
        let next = Self.state(of: phase)
        guard next.status != job.status || next.percent != job.percent || next.error != job.error else { return }
        job.status = next.status
        job.percent = next.percent
        job.error = next.error
        job.updatedAt = now()
        save(job)
    }

    /// A job's transcript was saved.
    func finished(audioURL: URL, transcriptID: Int64) {
        guard var job = jobsByPath[audioURL.path] else { return }
        job.status = .done
        job.percent = nil
        job.error = nil
        job.transcriptID = transcriptID
        job.updatedAt = now()
        save(job)
    }

    private static func state(
        of phase: MeetingRecorderCenter.ProcessingJob.Phase
    ) -> (status: HubSyncState.PhoneRecordingJob.Status, percent: Int?, error: String?) {
        switch phase {
        case .queued: return (.queued, nil, nil)
        case let .transcribing(done, total):
            // The first report is 0 of 0, before the window count is known.
            let percent = total > 0 ? min(100, max(0, done * 100 / total)) : 0
            return (.transcribing, percent, nil)
        case .diarizing: return (.diarizing, nil, nil)
        case .summarizing: return (.summarizing, nil, nil)
        case let .failed(message): return (.failed, nil, message)
        }
    }

    /// Remembers `job` and nudges the fast lane. A sidecar write failure is
    /// logged: the in-memory job keeps following the callbacks, and the next
    /// change writes the row again.
    private func save(_ job: HubSyncState.PhoneRecordingJob) {
        jobsByPath[job.audioPath] = job
        if let transcriptID = job.transcriptID {
            transcriptUploads.withLock { $0[transcriptID] = job.uploadID }
        }
        do {
            try sidecar.savePhoneRecording(job)
        } catch {
            logger.error("phone recording \(job.uploadID, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
        onChange?(job.transcriptID == nil ? [.recordingJob] : [.recordingJob, .meetingTranscript])
    }

    // MARK: - HubCompanion

    /// The hub calls it on the main actor.
    nonisolated func start() {
        MainActor.assumeIsolated { begin() }
    }

    nonisolated func stop() {
        MainActor.assumeIsolated { end() }
    }

    private func begin() {
        guard !isRunning else { return }
        isRunning = true
        guard let events else { return }
        let phase = events.onJobPhase
        let finished = events.onJobFinished
        previousPhase = phase
        previousFinished = finished
        events.onJobPhase = { [weak self] url, next in
            phase?(url, next)
            self?.phaseChanged(audioURL: url, phase: next)
        }
        events.onJobFinished = { [weak self] url, transcriptID in
            finished?(url, transcriptID)
            self?.finished(audioURL: url, transcriptID: transcriptID)
        }
    }

    private func end() {
        guard isRunning else { return }
        isRunning = false
        events?.onJobPhase = previousPhase
        events?.onJobFinished = previousFinished
        previousPhase = nil
        previousFinished = nil
    }
}
