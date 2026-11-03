import Foundation
import WatchtowerCore

/// The launch passes over `pending_transcripts` (#604 S3/S4):
/// `restorePendingOnLaunch` runs them after the legacy sidecar import.
extension MeetingRecorderCenter {
    /// UserDefaults flag: the one-time pass over an older build's audio ran.
    static let legacyAudioTombstonedKey = "recorder.legacyAudioTombstoned"
    /// UserDefaults date, written once: when this build first started. Only
    /// audio modified before it can be an older build's.
    static let legacyAudioCutoffKey = "recorder.legacyAudioCutoff"

    /// Stamps the cutoff on this build's first launch, before the pass can
    /// run (or fail, or wait for a database that never opens): a recording
    /// of a launch whose pass did not finish is never taken for a legacy one.
    func recordLegacyAudioCutoff() {
        guard !defaults.bool(forKey: Self.legacyAudioTombstonedKey),
              defaults.object(forKey: Self.legacyAudioCutoffKey) == nil else { return }
        defaults.set(launchedAt, forKey: Self.legacyAudioCutoffKey)
    }

    /// Once per install (the flag, set only when the pass finished): an older
    /// build kept a recording pending exactly while its `rec_X.meta` existed,
    /// so a `rec_*` audio file with no `.meta`, no row and no saved transcript
    /// was dismissed (or saved) there. It becomes a dismissed tombstone and is
    /// never offered again. Busy recordings and audio modified since this
    /// build first started (`legacyAudioCutoffKey`) are skipped: those are
    /// this version's.
    func tombstoneLegacyAudioOnce(store: PendingTranscriptStore, busy: Set<URL>) async {
        guard !defaults.bool(forKey: Self.legacyAudioTombstonedKey) else { return }
        let cutoff = defaults.object(forKey: Self.legacyAudioCutoffKey) as? Date ?? launchedAt
        let fm = FileManager.default
        do {
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: recordingsDirectory.path)
            } catch CocoaError.fileReadNoSuchFile {
                names = []
            }
            let rows = Set(try store.pending().map(\.recording))
            let saved = try store.savedAudioPaths()
            for name in names where name.hasPrefix("rec_")
                && Self.recordingAudioExtensions.contains((name as NSString).pathExtension) {
                let url = recordingsDirectory.appendingPathComponent(name)
                let meta = url.deletingPathExtension().appendingPathExtension("meta")
                let modified = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                guard !busy.contains(url), !rows.contains(name), !saved.contains(url.path),
                      !fm.fileExists(atPath: meta.path), let modified, modified < cutoff else { continue }
                try await store.dismiss(recording: name, at: clock())
            }
            defaults.set(true, forKey: Self.legacyAudioTombstonedKey)
        } catch {
            print("[MeetingRecorder] the one-time pass over older recordings failed, retried next launch: "
                  + error.localizedDescription)
        }
    }

    /// Removes the rows whose audio is gone (the daemon's orphan sweep took
    /// it, or it was deleted by hand), dismissed tombstones included: with no
    /// file there is nothing left to offer. Rows of busy recordings and rows
    /// written since this launch began (a phone recording still copying) stay.
    func prunePendingRows(store: PendingTranscriptStore, busy: Set<URL>) async {
        do {
            let fm = FileManager.default
            for row in try store.pending() where row.startedAt < launchedAt {
                let url = recordingsDirectory.appendingPathComponent(row.recording)
                guard !busy.contains(url), !fm.fileExists(atPath: url.path) else { continue }
                try await store.remove(recording: row.recording)
            }
        } catch {
            print("[MeetingRecorder] pruning the pending recordings failed: \(error.localizedDescription)")
        }
    }

    /// The recordings to recover, oldest first: the rows (not dismissed) whose
    /// audio is still in `directory`, then — merged in name order — every
    /// `rec_*` audio file there with no row and no saved transcript (its
    /// private flag unknown, so private: MEETPRIV fails closed, and the
    /// recovered pill's lock lets the owner open it before transcribing).
    static func recoverable(in directory: URL, store: PendingTranscriptStore) -> [RecoverableRecording] {
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
            byName[name] = RecoverableRecording(audioURL: url, eventID: nil, title: nil, isPrivate: true)
        }
        return byName.keys.sorted { recoverySortKey($0) < recoverySortKey($1) }.compactMap { byName[$0] }
    }

    /// Cancels Desktop's own processing of these phone recordings (audio
    /// file names) before the Go hub adopts them (go hub plan 3 Task 22): a
    /// queued job is withdrawn, a transcribing one cancelled, both awaited
    /// until their tasks end; a failed job and a recovered entry are dropped.
    /// A job whose save already started finishes (the save removes its row).
    /// None of them is resumed, completed or offered again this run, and
    /// their `pending_transcripts` rows stay until the Go hub took the
    /// recordings (`forgetPhoneRecordings`) or gave them back
    /// (`releasePhoneRecordings`). Idempotent: a second call finds nothing
    /// left to stop.
    func cancelPhoneRecordingJobs(audioNames: [String]) async {
        let names = Self.phoneNames(audioNames)
        guard !names.isEmpty else { return }
        let withdrawn = withdrawPhoneRecordingJobs(names)
        for task in withdrawn.cancelled + withdrawn.saving { await task.value }
        // A save that failed leaves a failed job: it goes now too.
        if !withdrawn.saving.isEmpty { _ = withdrawPhoneRecordingJobs(names) }
    }

    /// The Go hub took these recordings: their rows go (the audio moved
    /// with them).
    func forgetPhoneRecordings(audioNames: [String]) async {
        guard let store = pendingStore else { return }
        for name in Self.phoneNames(audioNames).sorted() {
            do {
                try await store.remove(recording: name)
            } catch {
                print("[MeetingRecorder] could not remove an adopted phone recording's row: \(error.localizedDescription)")
            }
        }
    }

    /// The adoption failed for good: these recordings are Desktop's again,
    /// offered like any recording found at launch.
    func releasePhoneRecordings(audioNames: [String]) async {
        let names = Self.phoneNames(audioNames)
        guard !names.isEmpty, let store = pendingStore else { return }
        uncancelPhoneRecordings(names)
        let busy = Set(jobs.map(\.audioURL))
        for entry in Self.recoverable(in: recordingsDirectory, store: store)
        where names.contains(entry.audioURL.lastPathComponent) && !busy.contains(entry.audioURL) {
            addRecoverable(entry)
        }
    }

    private static func phoneNames(_ audioNames: [String]) -> Set<String> {
        Set(audioNames.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty })
    }
}
