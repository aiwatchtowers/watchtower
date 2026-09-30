import Foundation
import WatchtowerCore

/// Per-cluster registry features derived from diarization + the mic/system
/// activity sidecar (spec §2.1). Pure.
struct ClusterFeatures: Equatable {
    /// Total diarized speech of the cluster, seconds.
    let speechSec: Double
    let channel: VoiceChannel
    /// Up to `clipsPerCluster` playback clips, each `clipMinSec...clipMaxSec`
    /// long and from a different speech run, spread across the meeting and
    /// in time order (`pickClips`).
    let clips: [ClipSpan]

    /// Trimmed off both ends of a segment so a clip never starts or ends on
    /// a neighbour's words (diarization boundaries are approximate).
    static let edgeTrimSec = 0.3
    /// Share of the cluster's decisive bins that must be system-dominant (or
    /// mic-dominant) to call the channel.
    static let channelShare = 0.6
    /// Same-speaker segments this close together are one speech run: the
    /// diarizer cuts a long turn at its chunk boundaries, and clips taken
    /// from those slices were back-to-back pieces of one turn.
    static let runJoinGapSec = 0.5
    /// Clips start at least this far apart when the cluster's speech allows,
    /// so the owner hears different moments of the meeting.
    static let clipSpreadSec = 60.0

    /// Keyed by `SpeakerSegment.speakerID`.
    static func compute(speakers: [SpeakerSegment], activity: MicActivity?) -> [String: Self] {
        Dictionary(grouping: speakers, by: \.speakerID).mapValues { segments in
            let speech = segments.reduce(0) { $0 + max(0, $1.endSec - $1.startSec) }
            return Self(speechSec: speech, channel: channel(segments, activity), clips: pickClips(segments))
        }
    }

    /// Joins the cluster's segments into speech runs, trims each run's edges,
    /// keeps runs long enough for a clip, and picks the longest ones whose
    /// starts lie `clipSpreadSec` apart — topping up with the next longest
    /// runs when too few are that far apart.
    private static func pickClips(_ segments: [SpeakerSegment]) -> [ClipSpan] {
        let eligible = runs(segments)
            .map { (start: $0.start + edgeTrimSec, end: $0.end - edgeTrimSec) }
            .filter { $0.end - $0.start >= VoiceRegistryPolicy.clipMinSec }
            .sorted { ($0.end - $0.start, $1.start) > ($1.end - $1.start, $0.start) }
        var picked: [(start: Double, end: Double)] = []
        for run in eligible where picked.count < VoiceRegistryPolicy.clipsPerCluster
            && picked.allSatisfy({ abs($0.start - run.start) >= clipSpreadSec }) {
            picked.append(run)
        }
        for run in eligible where picked.count < VoiceRegistryPolicy.clipsPerCluster
            && !picked.contains(where: { $0.start == run.start }) {
            picked.append(run)
        }
        return picked
            .sorted { $0.start < $1.start }
            .map { ClipSpan(start: $0.start, end: min($0.end, $0.start + VoiceRegistryPolicy.clipMaxSec)) }
    }

    private static func runs(_ segments: [SpeakerSegment]) -> [(start: Double, end: Double)] {
        var runs: [(start: Double, end: Double)] = []
        for segment in segments.sorted(by: { $0.startSec < $1.startSec }) {
            if let last = runs.last, segment.startSec - last.end <= runJoinGapSec {
                runs[runs.count - 1].end = max(last.end, segment.endSec)
            } else {
                runs.append((segment.startSec, segment.endSec))
            }
        }
        return runs
    }

    /// Same per-bin dominance test as `RoleAssigner` (factor 2): mic-dominant
    /// bins read as the room (the owner's mic), system-dominant ones as a
    /// remote participant; ambiguous bins do not vote.
    private static func channel(_ segments: [SpeakerSegment], _ activity: MicActivity?) -> VoiceChannel {
        guard let activity else { return .unknown }
        var mic = 0
        var sys = 0
        for segment in segments {
            var t = segment.startSec
            while t < segment.endSec {
                if let bin = activity.bin(at: t) {
                    if bin.mic > RoleAssigner.micDominanceFactor * bin.sys {
                        mic += 1
                    } else if bin.sys > RoleAssigner.micDominanceFactor * bin.mic {
                        sys += 1
                    }
                }
                t += MicActivity.binDuration
            }
        }
        let total = mic + sys
        guard total > 0 else { return .unknown }
        if Double(sys) / Double(total) >= channelShare { return .remote }
        if Double(mic) / Double(total) >= channelShare { return .room }
        return .unknown
    }
}
