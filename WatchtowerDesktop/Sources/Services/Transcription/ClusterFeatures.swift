import Foundation
import WatchtowerCore

/// Per-cluster registry features derived from diarization + the mic/system
/// activity sidecar (spec §2.1). Pure.
struct ClusterFeatures: Equatable {
    /// Total diarized speech of the cluster, seconds.
    let speechSec: Double
    let channel: VoiceChannel
    /// Up to `clipsPerCluster` playback clips from the cluster's longest
    /// segments, edge-trimmed, each `clipMinSec...clipMaxSec` long.
    let clips: [ClipSpan]

    /// Trimmed off both ends of a segment so a clip never starts or ends on
    /// a neighbour's words (diarization boundaries are approximate).
    static let edgeTrimSec = 0.3
    /// Share of the cluster's decisive bins that must be system-dominant (or
    /// mic-dominant) to call the channel.
    static let channelShare = 0.6

    /// Keyed by `SpeakerSegment.speakerID`.
    static func compute(speakers: [SpeakerSegment], activity: MicActivity?) -> [String: Self] {
        Dictionary(grouping: speakers, by: \.speakerID).mapValues { segments in
            let speech = segments.reduce(0) { $0 + max(0, $1.endSec - $1.startSec) }
            let clips = segments
                .map { (start: $0.startSec + edgeTrimSec, end: $0.endSec - edgeTrimSec) }
                .filter { $0.end - $0.start >= VoiceRegistryPolicy.clipMinSec }
                .sorted { ($0.end - $0.start, $1.start) > ($1.end - $1.start, $0.start) }
                .prefix(VoiceRegistryPolicy.clipsPerCluster)
                .map { ClipSpan(start: $0.start, end: min($0.end, $0.start + VoiceRegistryPolicy.clipMaxSec)) }
            return Self(speechSec: speech, channel: channel(segments, activity), clips: Array(clips))
        }
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
