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
}
