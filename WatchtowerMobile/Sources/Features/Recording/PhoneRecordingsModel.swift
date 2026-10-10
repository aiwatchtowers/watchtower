import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Where one phone recording stands on its way to the Mac, as the
/// recorder's Saved screen and the Recordings list (Task 8) show it. A
/// pending upload reads "Waiting for the Mac to wake" while the heartbeat
/// is stale or absent (spec §9): CloudKit holds the file until then.
enum PhoneUploadStage: Equatable {
    /// The capture is still being written on the phone.
    case recording
    case sending
    case waitingForMac
    case delivered
    /// `retryable` is false for a local failure a retry can only repeat
    /// (the file is gone, too large, or held no audio).
    case failed(String, retryable: Bool)

    init(recording: PhoneRecording, heartbeat: HeartbeatPayload?, now: Date) {
        switch recording.state {
        case .recording:
            self = .recording
        case .delivered:
            self = .delivered
        case .failed:
            self = .failed(recording.errorMessage ?? "Not sent to your Mac.", retryable: recording.offersRetry)
        case .waiting, .uploading:
            if case .online = MacStatus(heartbeat: heartbeat, now: now) {
                self = .sending
            } else {
                self = .waitingForMac
            }
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

    init(job: RecordingJob?) {
        guard let job else {
            self = .notStarted
            return
        }
        switch job.status {
        case .received, .queued: self = .inProgress("Queued on your Mac")
        case .transcribing: self = .inProgress("Transcribing on Mac · \(job.percent ?? 0)%")
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

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure.
    static func read(from db: Database, store: ReplicaStore) throws -> Self {
        var snapshot = Self()
        snapshot.recordings = try store.phoneRecordings(from: db)
        var skipped = 0
        for payload in try store.payloads(of: .recordingJob, from: db) {
            do {
                let job = try RelayCoder.makeDecoder().decode(RecordingJob.self, from: payload)
                snapshot.jobs[job.id] = job
            } catch {
                skipped += 1
            }
        }
        if skipped > 0 {
            logger.warning("\(skipped) undecodable recording_job records skipped")
        }
        snapshot.heartbeat = try SettingsSnapshot.decode(
            HeartbeatPayload.self,
            recordName: HeartbeatPayload.recordName,
            store: store,
            from: db
        )
        return snapshot
    }

    func recording(_ id: String) -> PhoneRecording? {
        recordings.first { $0.id == id }
    }
}

/// Live phone-recordings state: one observation for the app's lifetime,
/// re-read on every replica write.
@MainActor
@Observable
final class PhoneRecordingsModel {
    private(set) var snapshot = PhoneRecordingsSnapshot()
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "PhoneRecordingsModel")

    /// The recordings slices re-read on every replica write; a write that
    /// leaves them equal publishes nothing.
    nonisolated static func observation(
        store: ReplicaStore
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<PhoneRecordingsSnapshot>>> {
        ValueObservation.tracking { db in
            try PhoneRecordingsSnapshot.read(from: db, store: store)
        }
        .removeDuplicates()
    }

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = Self.observation(store: store).start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("recordings observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.snapshot = value }
            }
        )
    }
}
