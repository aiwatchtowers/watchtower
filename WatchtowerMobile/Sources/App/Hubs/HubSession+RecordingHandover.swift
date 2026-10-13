import Foundation
import os
import WatchtowerSync

/// What adopting the held recordings did (`HubSession.adoptHeld`).
struct HeldAdoption: Equatable, Sendable {
    /// Held recordings whose audio was gone, or too short to register:
    /// they cannot be sent ("Not sent").
    var lost = 0
    /// Why some held recordings could not be adopted now; they stay held
    /// and the next boot of their hub tries again.
    var problem: String?
}

/// What a wipe did with the outgoing session's recordings
/// (`HubSession.handOverRecordings`).
struct RecordingHandover: Equatable, Sendable {
    /// Recordings still on their way to the Mac that cannot be held (no
    /// audio, over the size cap, or not carried on an account change).
    var lost = 0
    /// The capture this wipe stopped was saved and is held.
    var stoppedCaptureKept = false
    /// Why some recordings could not be read: their audio was moved out of
    /// the sweep's reach (`.held/unreadable`), but it is not sent.
    var problem: String?
}

/// Recordings across a wipe (board #63). A wipe never deletes audio the Mac
/// has not acknowledged without saying so:
/// - before the replica goes, every recording whose audio is on the phone
///   and that the Mac has not acknowledged is *held* for the hub it was
///   recorded for (`RecordingHold`, outside the replica);
/// - a session adopts the held recordings of its own hub only, so a
///   recording never reaches another owner's Mac; the others wait, listed
///   in Recordings as waiting for their Mac;
/// - on an iCloud account change nothing is carried: the recordings were
///   made for the old account's Mac, and are reported "Not sent".
extension HubSession {
    nonisolated private static let handoverLogger = Logger(subsystem: "WatchtowerMobile", category: "RecordingHandover")

    /// After the outgoing session's shutdown (its boot, and so its own
    /// launch recovery, has ended): captures still `recording` are
    /// finalized from their files, then the recordings are held for this
    /// session's hub (`keep`), or counted lost. `stoppedCapture` is the
    /// capture the wipe stopped (`PhoneRecorderController.stopForWipe`).
    func handOverRecordings(stoppedCapture: String?, keep: Bool) async -> RecordingHandover {
        guard let hold, let recordings = uploader.directory else { return RecordingHandover() }
        var handover = RecordingHandover()
        var unreadable: String?
        do {
            try await recorder.recoverInterrupted()
        } catch {
            unreadable = error.localizedDescription
        }
        var held: [HeldRecording] = []
        do {
            let macName = heldMacName()
            for row in try store.phoneRecordings() {
                switch Self.disposition(of: row, directory: uploader.directory) {
                case .ignore:
                    continue
                case .lost:
                    handover.lost += 1
                case .finishLater:
                    // Recovery could not finalize it: its audio is protected.
                    unreadable = unreadable ?? "A recording could not be finished"
                case .hold:
                    guard keep else {
                        handover.lost += 1
                        continue
                    }
                    held.append(HeldRecording(row, marks: marks(of: row.id), hubID: hubID, macName: macName))
                }
            }
            if !keep {
                handover.lost += try hold.dropAll(recordingsDirectory: recordings)
            }
            try hold.hold(held, from: recordings)
            handover.stoppedCaptureKept = stoppedCapture.map { id in held.contains { $0.id == id } } ?? false
        } catch {
            unreadable = error.localizedDescription
        }
        if let reason = unreadable {
            Self.handoverLogger.error("recordings not handed over: \(reason, privacy: .public)")
            do {
                let (moved, failures) = try hold.protectUnreadable(in: recordings)
                handover.problem = "Some recordings couldn't be read (\(reason)): their audio stays on this iPhone, unsent"
                    + (moved == 1 ? " (1 file)" : " (\(moved) files)")
                if !failures.isEmpty {
                    Self.handoverLogger.error("audio not protected: \(failures.joined(separator: "; "), privacy: .public)")
                    handover.problem? += failures.count == 1
                        ? "; 1 file could not be kept and may be lost"
                        : "; \(failures.count) files could not be kept and may be lost"
                }
            } catch {
                handover.problem = "Some recordings couldn't be read (\(reason)) and may be lost"
            }
        }
        return handover
    }

    private enum Disposition {
        case ignore, lost, finishLater, hold
    }

    /// What a wipe does with one ledger row: delivered rows and local
    /// failures without audio are already settled; a row over the size cap
    /// can never be sent (lost); the rest is held when its audio is there.
    private static func disposition(of row: PhoneRecording, directory: URL?) -> Disposition {
        let hasAudio = FileManager.default.fileExists(atPath: row.fileURL(in: directory).path)
        switch row.state {
        case .delivered:
            return .ignore
        case .failed where row.failure == .tooLarge:
            return hasAudio ? .lost : .ignore
        case .failed where !row.offersRetry:
            return .ignore
        case .recording:
            return hasAudio ? .finishLater : .lost
        case .waiting, .uploading, .failed:
            return hasAudio ? .hold : .lost
        }
    }

    /// A row's marks; an unreadable set costs the marks, never the row.
    private func marks(of id: String) -> [Int] {
        do {
            return try store.phoneRecordingMarks(id: id)
        } catch {
            Self.handoverLogger.warning("marks of \(id, privacy: .public) not read: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The Mac's name for this hub, from its last heartbeat.
    private func heldMacName() -> String? {
        let heartbeat = try? store.reader.read { db in
            try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        }
        guard let heartbeat, heartbeat.hubID == hubID else { return nil }
        return heartbeat.macName
    }

    /// At boot, before the launch sweep: the held recordings of this
    /// session's hub become `waiting` rows again (sent once a device id
    /// is set); a recording whose row is already here only leaves the hold.
    /// Held recordings of other hubs stay held (`heldRecordings`).
    func adoptHeld() async -> HeldAdoption {
        guard let hold, let recordings = uploader.directory else { return HeldAdoption() }
        var report = HeldAdoption()
        let held: [HeldRecording]
        do {
            held = try hold.load()
        } catch {
            report.problem = "Held recordings couldn't be read (\(error.localizedDescription))"
            return report
        }
        var settled = Set<String>()
        var failures: [String] = []
        for recording in held where recording.hubID == hubID {
            do {
                if try store.phoneRecording(id: recording.id) != nil {
                    // Held but never wiped (a kill, or a replica that could
                    // not be removed): the row is here, the audio goes back
                    // next to it. A failed move keeps the entry held.
                    _ = try hold.restoreAudio(of: recording, to: recordings)
                    settled.insert(recording.id)
                    continue
                }
                guard let audio = try hold.restoreAudio(of: recording, to: recordings) else {
                    settled.insert(recording.id)
                    report.lost += 1
                    continue
                }
                do {
                    let row = try await uploader.register(
                        id: recording.id,
                        fileURL: audio,
                        startedAt: recording.startedAt,
                        endedAt: recording.endedAt,
                        activeDuration: TimeInterval(recording.durationSec),
                        titleHint: recording.titleHint,
                        eventID: recording.eventID,
                        marks: recording.marks
                    )
                    if row == nil { report.lost += 1 }
                    settled.insert(recording.id)
                } catch {
                    // Back out of the sweep's reach until the next boot.
                    try hold.hold([recording], from: recordings)
                    throw error
                }
            } catch {
                Self.handoverLogger.error(
                    "held recording \(recording.id, privacy: .public) not adopted: \(error.localizedDescription, privacy: .public)"
                )
                failures.append(error.localizedDescription)
            }
        }
        do {
            try hold.remove(ids: settled)
            heldRecordings = try hold.load()
        } catch {
            failures.append(error.localizedDescription)
        }
        if let first = failures.first {
            report.problem = failures.count == 1
                ? "A recording couldn't be restored yet (\(first)); it stays on this iPhone"
                : "\(failures.count) recordings couldn't be restored yet (\(first)); they stay on this iPhone"
        }
        return report
    }
}
