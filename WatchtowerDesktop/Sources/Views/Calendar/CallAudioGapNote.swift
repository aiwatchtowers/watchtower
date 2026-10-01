import Foundation
import WatchtowerCore

/// The recording-detail note for stretches with no call audio
/// (`CallAudioWatch` over the recording's `rec_X.activity` sidecar). Said as
/// a fact, never as a diagnosis: the call may have gone quiet or ended, or
/// its audio stopped reaching the recording — either way the transcript of
/// that stretch holds only the owner's microphone.
enum CallAudioGapNote {
    /// nil when there is nothing to say. `totalSec` is the recording's
    /// length, which closes an open-ended gap for the "in total" count.
    static func text(_ gaps: [CallAudioWatch.Gap], totalSec: Double) -> String? {
        guard let first = gaps.first else { return nil }
        let suffix = " — the transcript there holds only your microphone."
        if gaps.count <= 2 {
            let ranges = gaps.map { gap in
                "from \(TranscriptFormatting.formatTimecode(gap.startSec)) to "
                    + (gap.endSec.map(TranscriptFormatting.formatTimecode) ?? "the end")
            }
            return "No call audio " + ranges.joined(separator: " and ") + suffix
        }
        let silentSec = gaps.map { ($0.endSec ?? totalSec) - $0.startSec }.reduce(0, +)
        return "No call audio in \(gaps.count) stretches, \(Int((silentSec / 60).rounded())) min in total, "
            + "first at \(TranscriptFormatting.formatTimecode(first.startSec))" + suffix
    }

    /// Reads the sidecar next to `audioPath`; nil when there is none (an old
    /// recording, or one whose audio retention already swept it).
    static func load(audioPath: String?) -> String? {
        guard let audioPath, !audioPath.isEmpty,
              let activity = MicActivity.load(for: URL(fileURLWithPath: audioPath)) else { return nil }
        return text(CallAudioWatch.gaps(system: activity.bins.map(\.sys), binSec: MicActivity.binDuration),
                    totalSec: Double(activity.bins.count) * MicActivity.binDuration)
    }
}
