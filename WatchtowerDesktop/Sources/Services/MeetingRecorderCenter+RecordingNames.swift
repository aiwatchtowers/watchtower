import Foundation
import WatchtowerCore

/// Naming of the `rec_*` recording files: the audio extensions of the family,
/// the unique `rec_<timestamp>[-N].<ext>` name a new recording gets, and the
/// chronological sort key recovery orders them by.
extension MeetingRecorderCenter {
    /// Whether a recording name with this stem is held by a pending row (a
    /// reserved phone recording whose audio is not copied yet).
    nonisolated static func isReserved(_ stem: String, in store: PendingTranscriptStore?) -> Bool {
        guard let store else { return false }
        return recordingAudioExtensions.contains { ext in
            (try? store.transcript(recording: "\(stem).\(ext)")) != nil
        }
    }

    /// Audio extensions of the `rec_*` family: `.caf` from this Mac's own
    /// recorder, `.m4a` from phone recordings relayed by the mobile hub. Both
    /// are AVFoundation-readable, so the batch decode path is shared.
    nonisolated static let recordingAudioExtensions: Set<String> = ["caf", "m4a"]

    /// Chronological sort key for a `rec_<timestamp>[-N].<ext>` name: the
    /// timestamp, then the collision suffix as a number (absent = the first
    /// recording of that second). Plain lexicographic order gets a same-second
    /// pair backwards twice over — `-` sorts before `.`, so `rec_X-2.caf` would
    /// lead `rec_X.caf`, and `-10` would lead `-2` — which matters because the
    /// recovered pill acts on `recoverable.first`. Internal (not private) so the
    /// extension-agnostic stripping is testable on its own.
    static func recoverySortKey(_ name: String) -> (String, Int) {
        let base = (name as NSString).deletingPathExtension
        guard let dash = base.lastIndex(of: "-"),
              let suffix = Int(base[base.index(after: dash)...]) else { return (base, 1) }
        return (String(base[..<dash]), suffix)
    }

    nonisolated private static func timestampComponent(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    /// `rec_<timestamp>.<fileExtension>`, disambiguated with a `-N` suffix
    /// while the name is taken: by an audio file of EITHER extension
    /// (`rec_X.caf` and `rec_X.m4a` would share their pending row), by a
    /// legacy `.meta` sidecar not imported yet, or when `taken` says so (a
    /// pending row reserving the stem). The timestamp has one-second
    /// resolution, so two recordings started inside the same second would
    /// otherwise share a path — the second overwriting the first's audio.
    /// The `rec_` prefix and the timestamp stay: the Go orphan sweep matches
    /// on the family, and the name is what makes a recovered recording
    /// identifiable. Internal (not private) so the disambiguation is testable
    /// without racing the wall clock.
    nonisolated static func uniqueRecordingURL(
        in directory: URL,
        date: Date = Date(),
        fileExtension: String = "caf",
        taken: (String) -> Bool = { _ in false }
    ) -> URL {
        let base = "rec_\(timestampComponent(date))"
        func isTaken(_ stem: String) -> Bool {
            let stemURL = directory.appendingPathComponent(stem)
            let paths = recordingAudioExtensions.union([fileExtension, "meta"])
                .map { stemURL.appendingPathExtension($0).path }
            return paths.contains { FileManager.default.fileExists(atPath: $0) } || taken(stem)
        }
        var stem = base
        var suffix = 2
        while isTaken(stem) {
            stem = "\(base)-\(suffix)"
            suffix += 1
        }
        return directory.appendingPathComponent("\(stem).\(fileExtension)")
    }
}
