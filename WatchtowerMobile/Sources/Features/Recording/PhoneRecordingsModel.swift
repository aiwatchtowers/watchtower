import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Where one phone recording stands on its way to the Mac, as the
/// recorder's Saved screen and the Recordings list (Task 8) show it. A
/// pending upload reads "Waiting for the Mac to wake" while the heartbeat
/// is stale or absent (spec §9): CloudKit holds the file until then. An
/// upload out of automatic retries (board #724) reads "Upload stuck" and
/// offers Retry, like a failure — only while the Mac is online: waiting
/// for a sleeping Mac takes precedence.
enum PhoneUploadStage: Equatable {
    /// The capture is still being written on the phone.
    case recording
    case sending
    case waitingForMac
    case delivered
    /// `retryable` is false for a local failure a retry can only repeat
    /// (the file is gone, too large, or held no audio).
    case failed(String, retryable: Bool)

    /// The label of an upload past its attempt cap.
    static let stuckLabel = "Upload stuck"

    init(recording: PhoneRecording, heartbeat: HeartbeatPayload?, now: Date) {
        switch recording.state {
        case .recording:
            self = .recording
        case .delivered:
            self = .delivered
        case .failed:
            self = .failed(recording.errorMessage ?? "Not sent to your Mac.", retryable: recording.offersRetry)
        case .waiting, .uploading:
            // A sleeping Mac comes first: an upload waiting for it is not
            // stuck, whatever its attempts (the owner's Retry would change
            // nothing until the Mac wakes).
            guard case .online = MacStatus(heartbeat: heartbeat, now: now) else {
                self = .waitingForMac
                return
            }
            self = recording.isUploadStuck ? .failed(Self.stuckLabel, retryable: true) : .sending
        }
    }

    var label: String {
        switch self {
        case .recording: "Recording on the phone"
        case .sending: "Sending to your Mac"
        case .waitingForMac: "Waiting for the Mac to wake"
        case .delivered: "Sent to your Mac"
        case let .failed(message, _): message
        }
    }

    var offersRetry: Bool {
        if case let .failed(_, retryable) = self { return retryable }
        return false
    }
}

/// The Mac's side of one recording, from the `recording_job` slice:
/// nothing yet, transcribing with a percent, done, or failed.
enum PhoneTranscriptStage: Equatable {
    case notStarted
    case inProgress(String)
    case ready
    case failed(String)

    /// The Mac's percent clamped to 0…100 (nil is 0); every surface shows this.
    static func clampedPercent(_ percent: Int?) -> Int {
        min(100, max(0, percent ?? 0))
    }

    init(job: RecordingJob?) {
        guard let job else {
            self = .notStarted
            return
        }
        switch job.status {
        case .received, .queued: self = .inProgress("Queued on your Mac")
        case .transcribing: self = .inProgress("Transcribing on Mac · \(Self.clampedPercent(job.percent))%")
        case .diarizing: self = .inProgress("Finding speakers on your Mac")
        case .summarizing: self = .inProgress("Writing the recap on your Mac")
        case .done: self = .ready
        case .failed: self = .failed(job.error ?? "Transcription failed on your Mac.")
        }
    }
}

/// The phone's recordings as the replica holds them, read in one database
/// snapshot: the upload ledger, the Mac's `recording_job` records and the
/// heartbeat.
struct PhoneRecordingsSnapshot: Equatable {
    var recordings: [PhoneRecording] = []
    /// By upload id.
    var jobs: [String: RecordingJob] = [:]
    var heartbeat: HeartbeatPayload?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "PhoneRecordingsSnapshot")

    /// The slice kinds this snapshot decodes.
    static let kinds: [SliceKind] = [.recordingJob, .heartbeat]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation fetch. A kind whose change stamp is unchanged comes
    /// from `cache` undecoded; the default fresh cache decodes everything.
    /// The ledger is the phone's own table, read every time.
    static func read(from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache = ReplicaDecodeCache()) throws -> Self {
        let versions = try store.kindVersions(kinds, from: db)
        var snapshot = Self()
        snapshot.recordings = try store.phoneRecordings(from: db)
        snapshot.jobs = try cache.value(SliceKind.recordingJob.rawValue, version: versions[.recordingJob] ?? 0) {
            var jobs: [String: RecordingJob] = [:]
            var skipped = 0
            for payload in try store.payloads(of: .recordingJob, from: db) {
                do {
                    let job = try RelayCoder.makeDecoder().decode(RecordingJob.self, from: payload)
                    jobs[job.id] = job
                } catch {
                    skipped += 1
                }
            }
            if skipped > 0 {
                logger.warning("\(skipped) undecodable recording_job records skipped")
            }
            return jobs
        }
        snapshot.heartbeat = try cache.value(HeartbeatPayload.recordName, version: versions[.heartbeat] ?? 0) {
            try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        }
        return snapshot
    }

    func recording(_ id: String) -> PhoneRecording? {
        recordings.first { $0.id == id }
    }
}

/// Live phone-recordings state: one observation for the app's lifetime
/// over its kinds' change stamps and the recordings ledger.
@MainActor
@Observable
final class PhoneRecordingsModel {
    private(set) var snapshot = PhoneRecordingsSnapshot()
    /// The decoded kinds between reads (and the tests' decode counter).
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?

    /// Re-read when a stamp or the ledger changes; only the changed kinds
    /// decode again, and a read that leaves it equal publishes nothing.
    nonisolated static func observation(
        store: ReplicaStore,
        cache: ReplicaDecodeCache = ReplicaDecodeCache()
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<PhoneRecordingsSnapshot>>> {
        ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion] + ReplicaStore.phoneRecordingsRegions) { db in
            try PhoneRecordingsSnapshot.read(from: db, store: store, cache: cache)
        }
        .removeDuplicates()
    }

    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard cancellable == nil else { return }
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "recordings",
            reader: store.reader,
            gate: gate,
            observation: { Self.observation(store: store, cache: cache) },
            onChange: { [weak self] value in self?.snapshot = value }
        )
    }
}
