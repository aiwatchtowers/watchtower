import Foundation
import GRDB
import os
import WatchtowerCore

/// What the queue needs of the transcriber: observers of its job phases and
/// saved transcripts, keyed by the ingested audio file
/// (`MeetingRecorderCenter.addJobObserver`), and the recording an ingest
/// reserved for an upload (`phoneRecording(forUpload:)`).
@MainActor
protocol PhoneRecordingJobObserving: AnyObject {
    func addJobObserver(_ observer: MeetingRecorderCenter.JobObserver) -> UUID
    func removeJobObserver(_ token: UUID)
    func phoneRecording(forUpload uploadID: String) throws -> URL?
}

extension MeetingRecorderCenter: PhoneRecordingJobObserving {}

/// The Desktop's side of a phone recording on the Go hub (go hub plan 3
/// Task 17, spec §8 p. 4a). The hub writes the upload's audio and queues a
/// job; this queue claims it over the control socket (`recording_claim`,
/// whose answer names the audio file and its origin), hands the audio to the
/// transcriber's phone ingest, reports each phase back (`recording_progress`)
/// and ends the job with its transcript or a failure class, never text
/// (`recording_finish`). It replaces the Swift hub's `PhoneRecordingJobs`
/// once the Swift hub is gone (Task 24); until then both run, each acting
/// only on its own hub's uploads.
///
/// The hub's audio is the only copy (the phone deleted its own on
/// `received`): it is removed only once the transcript is saved; on any
/// failure it stays, until the hub's 31-day prune. A failed ingest is
/// reported with its class and tried again with a backoff (30 s doubling to
/// 30 min), except `not_audio`; a database not open yet and a calendar read
/// error are tried again unreported. The upload is remembered as
/// `ingesting` before the ingest starts, and the ingest's reservation keeps
/// the upload id, so a crash in between finds the recording again
/// (`phoneRecording(forUpload:)`) instead of ingesting it twice.
///
/// It acts on `recording_queued` events and on a rescan of
/// `hub recording list --json` each time the watch connects. A failure the
/// hub did not get from this queue (`hub_moved`, an adopted Swift one) is
/// never claimed. Remembered: ids, the Mac's recording path, the hub's audio
/// path and a finish the hub has not taken yet, in the app's defaults; the
/// sidecar is never opened. One serial chain carries every hub exchange.
/// Logs carry upload ids and classes only (FILES-01).
@MainActor
final class PhoneRecordingQueue {
    /// Lands the audio in the transcriber's queue, linked to `eventID`,
    /// titled `title` and reserved under `uploadID`; returns the ingested
    /// file, the key its job callbacks report under. Production:
    /// `MeetingRecorderCenter.ingestPhoneRecording`.
    typealias Ingest = @MainActor (_ audio: URL, _ eventID: String?, _ title: String?, _ uploadID: String) async throws -> URL
    /// The title of a calendar event on this Mac; nil when it is not here;
    /// throws when the calendar cannot be read.
    typealias EventTitle = @MainActor (_ eventID: String) async throws -> String?
    typealias Sleep = @Sendable (Duration) async -> Void

    /// One upload this Desktop took.
    struct Tracked: Codable, Equatable {
        enum Stage: String, Codable {
            /// The ingest started; it may have reserved and copied before a crash.
            case ingesting
            /// The transcriber holds it at `path`.
            case ingested
        }

        var stage: Stage
        /// The ingested recording on the Mac (set once ingested).
        var path: String?
        /// The hub's copy, removed once the transcript is saved.
        var hubAudio: String
        /// A finish the hub has not taken yet, sent again at the next rescan.
        var pendingTranscript: Int64?
        var pendingError: String?
        /// The hub holds the job failed: a later phase (the owner's Retry) claims it again.
        var failed = false
    }

    /// `hub recording list --json` (pinned keys): `ready` false = no queue to read yet.
    struct Listing: Decodable {
        let ready: Bool
        let jobs: [Row]
    }

    struct Row: Decodable, Equatable {
        let uploadID: String
        let status: String
        let audioPath: String
        let errorClass: String

        private enum CodingKeys: String, CodingKey {
            case status
            case uploadID = "upload_id"
            case audioPath = "audio_path"
            case errorClass = "error_class"
        }
    }

    /// The classes a failure is reported as (Go `state.ClassNoSpeech` …, a
    /// Go↔Swift dual path): the hub's `recording_job` slice shows a fixed
    /// sentence for each (Go `TestRecordingFailureTextsPinned`).
    enum FailureClass: String, CaseIterable {
        case noSpeech = "no_speech"
        case transcriptionFailed = "transcription_failed"
        case notAudio = "not_audio"
        case unreadable
        case ingestFailed = "ingest_failed"
        case missingAudio = "missing_audio"

        /// The queue tries these again on its own (the phone's text says so).
        var retried: Bool { self == .unreadable || self == .ingestFailed }
    }

    /// The queue's job phases as the hub takes them (Go `state.Phase…`).
    enum Phase {
        static let transcribing = "transcribing"
        static let diarizing = "diarizing"
        static let summarizing = "summarizing"
    }

    nonisolated static let listArgs = ["hub", "recording", "list", "--json"]
    nonisolated static let defaultsKey = "mobile.goHub.phoneRecordings"
    /// Set while the remembered uploads could not be read: a claimed job this
    /// queue does not know is then never ingested again on a guess.
    nonisolated static let lostKey = "mobile.goHub.phoneRecordingsLost"
    /// The transcriber's base message for a recording with no speech
    /// (`MeetingRecorderCenter.noSpeechMessage`).
    nonisolated static let noSpeechPrefix = "No speech recognized"
    nonisolated static let firstRetry: Duration = .seconds(30)
    nonisolated static let maxRetry: Duration = .seconds(30 * 60)

    private let client: any HubControlClienting
    private let cli: (any CLIRunnerProtocol)?
    private weak var observing: (any PhoneRecordingJobObserving)?
    private let defaults: UserDefaults
    private let ingest: Ingest
    private let eventTitle: EventTitle
    private let removeFile: (URL) throws -> Void
    private let fileExists: (URL) -> Bool
    private let sleep: Sleep
    private static let logger = Logger(subsystem: "com.watchtower.desktop", category: "PhoneRecordingQueue")

    /// Upload id → what this Desktop took.
    private(set) var tracked: [String: Tracked]
    private(set) var bookkeepingLost: Bool
    /// The last progress sent per upload (phase, percent), so an unchanged one is not sent again.
    private var lastProgress: [String: Report] = [:]
    private var attempts: [String: Int] = [:]
    private var retries: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var observer: UUID?

    private struct Report: Equatable {
        let phase: String
        let percent: Int?
    }

    init(
        client: any HubControlClienting,
        cli: (any CLIRunnerProtocol)?,
        observing: (any PhoneRecordingJobObserving)?,
        defaults: UserDefaults = .standard,
        removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
        eventTitle: @escaping EventTitle,
        ingest: @escaping Ingest
    ) {
        self.client = client
        self.cli = cli
        self.observing = observing
        self.defaults = defaults
        self.removeFile = removeFile
        self.fileExists = fileExists
        self.sleep = sleep
        self.eventTitle = eventTitle
        self.ingest = ingest
        let (loaded, lost) = Self.load(defaults)
        tracked = loaded
        bookkeepingLost = lost || defaults.bool(forKey: Self.lostKey)
        if lost {
            defaults.set(true, forKey: Self.lostKey)
            Self.logger.error("phone recordings: the remembered uploads are unreadable; claimed jobs are matched by upload id only")
        }
    }

    /// The app's queue on the hub's socket: the audio goes through the
    /// transcriber's phone ingest with Settings' transcription config, the
    /// event's title read from this Mac's calendar.
    static func live(
        cli: (any CLIRunnerProtocol)?, recorder: MeetingRecorderCenter, dbPool: DatabasePool
    ) -> PhoneRecordingQueue {
        PhoneRecordingQueue(
            client: HubControlClient(socketPath: HubControlClient.defaultSocketPath()), cli: cli, observing: recorder,
            eventTitle: { id in try await dbPool.read { try CalendarQueries.fetchEventLink($0, id: id)?.title } },
            ingest: { [weak recorder] audio, eventID, title, uploadID in
                guard let recorder else { throw CancellationError() }
                return try await recorder.ingestPhoneRecording(
                    audioURL: audio, eventID: eventID, title: title, uploadID: uploadID, config: .fromDefaults()
                )
            }
        )
    }

    /// The phone's title for a recording with no event (`PhoneRecorderController`'s
    /// voice note, a Kit↔Desktop dual path): "Voice note — d MMM, HH:mm", in
    /// this Mac's time zone (the phone formats in its own; they differ only
    /// when the two are set to different zones).
    nonisolated static func voiceNoteTitle(_ startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM, HH:mm"
        return "Voice note — \(formatter.string(from: startedAt))"
    }

    // MARK: - Lifecycle

    func start() {
        guard observer == nil, let observing else { return }
        observer = observing.addJobObserver(.init(
            phase: { [weak self] url, phase in self?.phaseChanged(audioURL: url, phase: phase) },
            finished: { [weak self] url, transcriptID in self?.finished(audioURL: url, transcriptID: transcriptID) }
        ))
    }

    func stop() {
        if let observer { observing?.removeJobObserver(observer) }
        observer = nil
        retries.values.forEach { $0.cancel() }
        retries = [:]
    }

    /// Waits until every exchange queued so far is done (tests).
    func idle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    // MARK: - Hub events

    /// The hub queued `uploadID`: claim and ingest it.
    func recordingQueued(_ uploadID: String) {
        enqueue { await $0.take(uploadID) }
    }

    /// The watch connected: the queue as the hub holds it, read again.
    func rescan() {
        enqueue { await $0.runRescan() }
    }

    private func runRescan() async {
        guard let listing = await list() else { return }
        guard listing.ready else {
            Self.logger.notice("phone recordings: the hub's queue is not ready; rescan skipped")
            return
        }
        let rows = listing.jobs
        // Bookkeeping goes only for a job the hub listed done, or no longer
        // lists at all while it lists others (never on an empty answer).
        let listed = Dictionary(rows.map { ($0.uploadID, $0) }) { first, _ in first }
        for (id, _) in tracked where listed[id]?.status == "done" || (!rows.isEmpty && listed[id] == nil) {
            forget(id)
        }
        save()
        var ambiguous = false
        for row in rows.sorted(by: { $0.uploadID < $1.uploadID }) {
            switch row.status {
            case "queued":
                if tracked[row.uploadID] == nil { await take(row.uploadID) }
            case "claimed":
                ambiguous = await resume(row) || ambiguous
            case "failed":
                if tracked[row.uploadID]?.pendingError != nil {
                    tracked[row.uploadID]?.pendingError = nil // the hub took it before the answer was lost
                    save()
                }
                if tracked[row.uploadID] == nil, FailureClass(rawValue: row.errorClass)?.retried == true {
                    await take(row.uploadID) // a retry a restart interrupted
                }
            default:
                break
            }
        }
        if bookkeepingLost, !ambiguous {
            bookkeepingLost = false
            defaults.removeObject(forKey: Self.lostKey)
        }
    }

    /// A claimed job at a rescan; whether it was left alone undecided (lost bookkeeping).
    private func resume(_ row: Row) async -> Bool {
        let id = row.uploadID
        if let entry = tracked[id], entry.stage == .ingested {
            await resendFinish(id, entry)
            return false
        }
        // Ingesting when the app stopped, or never remembered: the ingest's
        // reservation, found by upload id, tells whether it landed.
        let found: URL?
        do {
            found = try observing?.phoneRecording(forUpload: id)
        } catch {
            Self.logger.notice("phone recording \(id, privacy: .public): pending recordings unreadable, next rescan")
            return false
        }
        if let found {
            tracked[id] = Tracked(stage: .ingested, path: found.path, hubAudio: tracked[id]?.hubAudio ?? row.audioPath)
            save()
            return false
        }
        if tracked[id] == nil, bookkeepingLost {
            Self.logger.error("phone recording \(id, privacy: .public): claimed, not remembered; left for the owner")
            return true
        }
        tracked[id] = nil
        save()
        await take(id)
        return false
    }

    private func list() async -> Listing? {
        guard let cli else { return nil }
        do {
            return try JSONDecoder().decode(Listing.self, from: try await cli.run(args: Self.listArgs))
        } catch {
            Self.logger.error("phone recordings: the hub's queue unreadable (\(Self.code(error), privacy: .public))")
            return nil
        }
    }

    /// Claims `uploadID` and hands its audio to the transcriber. A refused
    /// claim (done, `hub_moved`, a failure this queue did not report) or no
    /// hub leaves it alone. The hub's audio stays whatever happens here.
    private func take(_ uploadID: String) async {
        guard tracked[uploadID] == nil else { return } // ours already: the callbacks follow it
        guard let answer = await send(.claim(uploadID)), let path = answer.audioPath, !path.isEmpty else { return }
        let audio = URL(fileURLWithPath: path)
        guard fileExists(audio) else {
            await finish(uploadID, failure: .missingAudio)
            return
        }
        let origin: (eventID: String?, title: String?)
        do {
            origin = try await self.origin(of: answer)
        } catch {
            Self.logger.notice("phone recording \(uploadID, privacy: .public): calendar unreadable, tried again later")
            retryLater(uploadID)
            return
        }
        tracked[uploadID] = Tracked(stage: .ingesting, hubAudio: path)
        save()
        do {
            let ingested = try await ingest(audio, origin.eventID, origin.title, uploadID)
            tracked[uploadID]?.stage = .ingested
            tracked[uploadID]?.path = ingested.path
            attempts[uploadID] = nil
            save()
        } catch {
            // Nothing landed: the ingest removes what it reserved or copied.
            tracked[uploadID] = nil
            save()
            guard let failure = Self.failureClass(ingestError: error) else {
                Self.logger.notice("phone recording \(uploadID, privacy: .public): ingest deferred")
                retryLater(uploadID)
                return
            }
            await finish(uploadID, failure: failure)
            if failure.retried { retryLater(uploadID) }
        }
    }

    /// Tries `uploadID` again after the backoff (30 s doubling to 30 min).
    private func retryLater(_ uploadID: String) {
        let attempt = (attempts[uploadID] ?? 0) + 1
        attempts[uploadID] = attempt
        let delay = min(Self.firstRetry * (1 << min(attempt - 1, 16)), Self.maxRetry)
        retries[uploadID]?.cancel()
        retries[uploadID] = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.retries[uploadID] = nil
            self.enqueue { await $0.take(uploadID) }
        }
    }

    /// The event and title the phone gave the recording, from its origin:
    /// an event on this Mac links it and gives the event's title, as the
    /// phone titles a meeting recording; an event this Mac's calendar lacks
    /// is dropped (saved ad-hoc, as the Swift hub did) and the title with
    /// it, since the title is never stored; no event is the phone's voice
    /// note, titled by its start. A calendar read error throws.
    private func origin(of answer: HubControlAnswer) async throws -> (eventID: String?, title: String?) {
        if let id = answer.eventID {
            if let title = try await eventTitle(id) { return (id, title) }
            Self.logger.info("phone recording \(answer.uploadID ?? "", privacy: .public): event not on this Mac, ingested ad-hoc")
            return (nil, nil)
        }
        return (nil, answer.startedAt.map { Self.voiceNoteTitle($0) })
    }

    // MARK: - Transcriber callbacks

    func phaseChanged(audioURL: URL, phase: MeetingRecorderCenter.ProcessingJob.Phase) {
        guard let uploadID = upload(forPath: audioURL.path) else { return }
        let report: Report
        switch phase {
        case .queued:
            if tracked[uploadID]?.failed == true { enqueue { await $0.reclaim(uploadID) } }
            return
        case let .transcribing(done, total):
            // The first report is 0 of 0, before the window count is known.
            report = Report(phase: Phase.transcribing, percent: total > 0 ? min(100, max(0, done * 100 / total)) : 0)
        case .diarizing:
            report = Report(phase: Phase.diarizing, percent: nil)
        case .summarizing:
            report = Report(phase: Phase.summarizing, percent: nil)
        case let .failed(message):
            let failure = Self.failureClass(transcriberMessage: message)
            tracked[uploadID]?.pendingError = failure.rawValue
            tracked[uploadID]?.failed = true
            lastProgress[uploadID] = nil
            save()
            enqueue { await $0.finish(uploadID, failure: failure) }
            return
        }
        enqueue { await $0.progress(uploadID, report) }
    }

    func finished(audioURL: URL, transcriptID: Int64) {
        guard let uploadID = upload(forPath: audioURL.path) else { return }
        tracked[uploadID]?.pendingTranscript = transcriptID
        save()
        enqueue { await $0.finish(uploadID, transcriptID: transcriptID) }
    }

    private func progress(_ uploadID: String, _ report: Report) async {
        if tracked[uploadID]?.failed == true { await reclaim(uploadID) }
        guard tracked[uploadID]?.failed == false, lastProgress[uploadID] != report else { return }
        if await send(.progress(uploadID, phase: report.phase, percent: report.percent)) != nil {
            lastProgress[uploadID] = report
        }
    }

    /// The owner retried a failed transcription: the hub's job is claimed again.
    private func reclaim(_ uploadID: String) async {
        guard tracked[uploadID]?.failed == true, await send(.claim(uploadID)) != nil else { return }
        tracked[uploadID]?.failed = false
        tracked[uploadID]?.pendingError = nil
        save()
    }

    /// The transcript is saved: the hub's copy of the audio goes now, the
    /// first moment it is no longer the only one that matters.
    private func finish(_ uploadID: String, transcriptID: Int64) async {
        if tracked[uploadID]?.failed == true { await reclaim(uploadID) }
        guard await send(.finish(uploadID, transcriptID: transcriptID)) != nil else { return }
        if let hubAudio = tracked[uploadID]?.hubAudio {
            do {
                try removeFile(URL(fileURLWithPath: hubAudio))
            } catch {
                Self.logger.error("phone recording \(uploadID, privacy: .public): hub copy not removed (\(Self.code(error), privacy: .public))")
            }
        }
        forget(uploadID)
        save()
    }

    private func finish(_ uploadID: String, failure: FailureClass) async {
        guard await send(.finish(uploadID, errorClass: failure.rawValue)) != nil else { return }
        if tracked[uploadID] != nil {
            tracked[uploadID]?.pendingError = nil
            save()
        }
    }

    private func resendFinish(_ uploadID: String, _ entry: Tracked) async {
        if let transcriptID = entry.pendingTranscript {
            await finish(uploadID, transcriptID: transcriptID)
        } else if let raw = entry.pendingError, let failure = FailureClass(rawValue: raw) {
            await finish(uploadID, failure: failure)
        }
    }

    private func forget(_ uploadID: String) {
        tracked[uploadID] = nil
        lastProgress[uploadID] = nil
        attempts[uploadID] = nil
        retries.removeValue(forKey: uploadID)?.cancel()
    }

    // MARK: - Hub exchange

    /// One request; the answer when the hub took it, else nil (logged
    /// unless simply no hub).
    private func send(_ request: HubControlRequest) async -> HubControlAnswer? {
        let what = "phone recording \(request.upload ?? ""): \(request.op)"
        do {
            let answer = try await client.send(request)
            guard answer.ok else {
                Self.logger.notice("\(what, privacy: .public) refused (\(answer.error ?? "", privacy: .public))")
                return nil
            }
            return answer
        } catch HubControlError.noHub {
            return nil
        } catch {
            Self.logger.error("\(what, privacy: .public) failed (\(Self.code(error), privacy: .public))")
            return nil
        }
    }

    private func enqueue(_ work: @escaping @MainActor (PhoneRecordingQueue) async -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    // MARK: - Classes

    /// A transcriber failure's class: no speech, else a failed transcription.
    nonisolated static func failureClass(transcriberMessage message: String) -> FailureClass {
        message.hasPrefix(noSpeechPrefix) ? .noSpeech : .transcriptionFailed
    }

    /// An ingest failure's class; nil for one tried again unreported (the
    /// database not open yet).
    nonisolated static func failureClass(ingestError error: any Error) -> FailureClass? {
        switch error as? MeetingRecorderCenter.PhoneIngestError {
        case .notAudio: .notAudio
        case .unreadable: .unreadable
        case .databaseUnavailable: nil
        case nil: .ingestFailed
        }
    }

    // MARK: - Remembered uploads

    private func upload(forPath path: String) -> String? {
        tracked.first { $0.value.path == path }?.key
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(tracked), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("phone recordings: not remembered (\(Self.code(error), privacy: .public))")
        }
    }

    /// The remembered uploads, and whether an entry was there but unreadable.
    private static func load(_ defaults: UserDefaults) -> ([String: Tracked], lost: Bool) {
        guard let data = defaults.data(forKey: defaultsKey) else { return ([:], false) }
        guard let decoded = try? JSONDecoder().decode([String: Tracked].self, from: data) else { return ([:], true) }
        return (decoded, false)
    }

    /// A loggable code: the error's domain and number, never its text (it may name a file).
    nonisolated private static func code(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain).\(ns.code)"
    }
}
