import Foundation
import os
import WatchtowerCore

/// What the queue needs of the transcriber: observers of its job phases and
/// saved transcripts, keyed by the ingested audio file
/// (`MeetingRecorderCenter.addJobObserver`).
@MainActor
protocol PhoneRecordingJobObserving: AnyObject {
    func addJobObserver(_ observer: MeetingRecorderCenter.JobObserver) -> UUID
    func removeJobObserver(_ token: UUID)
}

extension MeetingRecorderCenter: PhoneRecordingJobObserving {}

/// The Desktop's side of a phone recording on the Go hub (go hub plan 3
/// Task 17, spec §8 p. 4a). The hub writes the upload's audio and queues a
/// job; this queue claims it over the control socket (`recording_claim`,
/// whose answer names the audio file), hands the audio to the transcriber's
/// phone ingest, reports each phase back (`recording_progress`) and ends the
/// job with its transcript or a failure class, never text
/// (`recording_finish`). It replaces the Swift hub's `PhoneRecordingJobs` once the
/// Swift hub is gone (Task 24); until then both run, each acting only on its
/// own hub's uploads, so the Go path runs exactly while the Go hub serves
/// its socket.
///
/// It acts on `recording_queued` events and on a rescan of
/// `hub recording list --json` each time the watch connects (the jobs queued
/// while no watch listened, and those this Desktop claimed before a
/// restart). A job the hub holds failed — `hub_moved` (adoption) among
/// them — is never claimed from the list; only the owner's Retry of a
/// failure this queue reported claims one again. The uploads it took are
/// remembered across launches (ids, the Mac's own recording path, a finish
/// the hub has not taken yet) in the app's defaults; the sidecar is never
/// opened. One serial chain carries every hub exchange, so a job's reports
/// reach the hub in order. Logs carry upload ids and classes only (FILES-01).
@MainActor
final class PhoneRecordingQueue {
    /// Lands the audio in the transcriber's queue; returns the ingested
    /// file, the key its job callbacks report under. Production:
    /// `MeetingRecorderCenter.ingestPhoneRecording`.
    typealias Ingest = @MainActor (_ audio: URL) async throws -> URL

    /// One upload this Desktop took.
    struct Tracked: Codable, Equatable {
        /// The ingested recording on the Mac.
        var path: String
        /// A finish the hub has not taken yet, sent again at the next rescan.
        var pendingTranscript: Int64?
        var pendingError: String?
        /// The hub holds the job failed: a later phase (the owner's Retry) claims it again.
        var failed = false
    }

    /// One row of `hub recording list --json` (pinned keys).
    struct Row: Decodable, Equatable {
        let uploadID: String
        let status: String
        let audioPath: String

        private enum CodingKeys: String, CodingKey {
            case status
            case uploadID = "upload_id"
            case audioPath = "audio_path"
        }
    }

    /// The classes a failure is reported as (Go `state.ClassNoSpeech` …, a
    /// Go↔Swift dual path): the hub's `recording_job` slice shows the Swift
    /// hub's sentence for each (Go `TestRecordingFailureTextsPinned`).
    enum FailureClass: String, CaseIterable {
        case noSpeech = "no_speech"
        case transcriptionFailed = "transcription_failed"
        case notAudio = "not_audio"
        case unreadable
        case ingestFailed = "ingest_failed"
        case missingAudio = "missing_audio"
    }

    /// The queue's job phases as the hub takes them (Go `state.Phase…`).
    enum Phase {
        static let transcribing = "transcribing"
        static let diarizing = "diarizing"
        static let summarizing = "summarizing"
    }

    nonisolated static let listArgs = ["hub", "recording", "list", "--json"]
    nonisolated static let defaultsKey = "mobile.goHub.phoneRecordings"
    /// The transcriber's base message for a recording with no speech
    /// (`MeetingRecorderCenter.noSpeechMessage`).
    nonisolated static let noSpeechPrefix = "No speech recognized"

    private let client: any HubControlClienting
    private let cli: (any CLIRunnerProtocol)?
    private weak var observing: (any PhoneRecordingJobObserving)?
    private let defaults: UserDefaults
    private let ingest: Ingest
    private let removeFile: (URL) throws -> Void
    private let fileExists: (URL) -> Bool
    private static let logger = Logger(subsystem: "com.watchtower.desktop", category: "PhoneRecordingQueue")

    /// Upload id → what this Desktop took.
    private(set) var tracked: [String: Tracked]
    /// The last progress sent per upload (phase, percent), so an unchanged one is not sent again.
    private var lastProgress: [String: Report] = [:]
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
        ingest: @escaping Ingest
    ) {
        self.client = client
        self.cli = cli
        self.observing = observing
        self.defaults = defaults
        self.removeFile = removeFile
        self.fileExists = fileExists
        self.ingest = ingest
        tracked = Self.load(defaults)
    }

    /// The app's queue on the hub's socket: the audio goes through the
    /// transcriber's phone ingest with Settings' transcription config.
    static func live(cli: (any CLIRunnerProtocol)?, recorder: MeetingRecorderCenter) -> PhoneRecordingQueue {
        PhoneRecordingQueue(
            client: HubControlClient(socketPath: HubControlClient.defaultSocketPath()), cli: cli, observing: recorder
        ) { [weak recorder] audio in
            guard let recorder else { throw CancellationError() }
            return try await recorder.ingestPhoneRecording(audioURL: audio, eventID: nil, title: nil, config: .fromDefaults())
        }
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
        guard let rows = await list() else { return }
        let listed = Dictionary(rows.map { ($0.uploadID, $0) }) { first, _ in first }
        for (id, _) in tracked where listed[id] == nil || listed[id]?.status == "done" {
            tracked[id] = nil
            lastProgress[id] = nil
        }
        save()
        for row in rows.sorted(by: { $0.uploadID < $1.uploadID }) {
            switch row.status {
            case "queued":
                await take(row.uploadID)
            case "claimed":
                if let entry = tracked[row.uploadID] {
                    await resendFinish(row.uploadID, entry)
                } else {
                    await take(row.uploadID)
                }
            case "failed":
                // The hub took the failure before the answer was lost.
                if tracked[row.uploadID]?.pendingError != nil {
                    tracked[row.uploadID]?.pendingError = nil
                    save()
                }
            default:
                break
            }
        }
    }

    private func list() async -> [Row]? {
        guard let cli else { return nil }
        do {
            return try JSONDecoder().decode([Row].self, from: try await cli.run(args: Self.listArgs))
        } catch {
            Self.logger.error("phone recordings: the hub's queue unreadable (\(Self.code(error), privacy: .public))")
            return nil
        }
    }

    /// Claims `uploadID` and hands its audio to the transcriber. A refused
    /// claim (done, failed, `hub_moved`) or no hub leaves it alone; a
    /// transient ingest failure (the database not open yet) leaves it
    /// claimed for the next rescan; any other failure ends the job with its class.
    private func take(_ uploadID: String) async {
        guard tracked[uploadID] == nil else { return } // ours already: the callbacks follow it
        guard let answer = await send(.claim(uploadID)), let path = answer.audioPath, !path.isEmpty else { return }
        let audio = URL(fileURLWithPath: path)
        guard fileExists(audio) else {
            await finish(uploadID, failure: .missingAudio)
            return
        }
        let ingested: URL
        do {
            ingested = try await ingest(audio)
        } catch {
            guard let failure = Self.failureClass(ingestError: error) else {
                Self.logger.notice("phone recording \(uploadID, privacy: .public): ingest deferred")
                return
            }
            // A failed job is never taken again; unsent, the next rescan takes it again.
            if await finish(uploadID, failure: failure) { removeHubCopy(audio, uploadID) }
            return
        }
        tracked[uploadID] = Tracked(path: ingested.path)
        save()
        removeHubCopy(audio, uploadID) // the transcriber copied it
    }

    /// The hub's plaintext copy of a claimed job's audio is Desktop's to
    /// remove (the Swift hub removed its decrypted copy after the ingest).
    private func removeHubCopy(_ audio: URL, _ uploadID: String) {
        do {
            try removeFile(audio)
        } catch {
            Self.logger.error("phone recording \(uploadID, privacy: .public): hub copy not removed (\(Self.code(error), privacy: .public))")
        }
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

    private func finish(_ uploadID: String, transcriptID: Int64) async {
        if tracked[uploadID]?.failed == true { await reclaim(uploadID) }
        guard await send(.finish(uploadID, transcriptID: transcriptID)) != nil else { return }
        tracked[uploadID] = nil
        lastProgress[uploadID] = nil
        save()
    }

    /// Whether the hub took the failure.
    @discardableResult
    private func finish(_ uploadID: String, failure: FailureClass) async -> Bool {
        guard await send(.finish(uploadID, errorClass: failure.rawValue)) != nil else { return false }
        if tracked[uploadID] != nil {
            tracked[uploadID]?.pendingError = nil
            save()
        }
        return true
    }

    private func resendFinish(_ uploadID: String, _ entry: Tracked) async {
        if let transcriptID = entry.pendingTranscript {
            await finish(uploadID, transcriptID: transcriptID)
        } else if let raw = entry.pendingError, let failure = FailureClass(rawValue: raw) {
            await finish(uploadID, failure: failure)
        }
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

    /// An ingest failure's class; nil for a transient one (the database not
    /// open yet), which is tried again rather than reported.
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

    private static func load(_ defaults: UserDefaults) -> [String: Tracked] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Tracked].self, from: data)) ?? [:]
    }

    /// A loggable code: the error's domain and number, never its text (it may name a file).
    nonisolated private static func code(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain).\(ns.code)"
    }
}
