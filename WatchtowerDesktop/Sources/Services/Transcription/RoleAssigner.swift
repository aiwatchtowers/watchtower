import Foundation

/// Pure mapping of a diarized speaker timeline onto timestamped transcript
/// segments, plus rendering of the final role-tagged text. No I/O.
enum RoleAssigner {
    private static let selfLabel = "Я"
    /// Mic RMS must exceed system RMS by this factor for a bin to read as
    /// "the owner is speaking" (the mic channel leaks meeting audio quietly).
    private static let micDominanceFactor: Float = 2.0
    /// Minimum share of a cluster's speech bins with mic dominance for the
    /// cluster to be labelled as the owner.
    private static let selfShareThreshold = 0.6
    /// Consecutive same-cluster segments merge into one utterance only up to
    /// this span; beyond it a new utterance with the same speaker label is
    /// started. Without the cap a diarization under-split (several people
    /// collapsed into one cluster) cements hundreds of seconds into a single
    /// unreadable block and takes the per-utterance actions (soft delete,
    /// speaker rename review) down with it.
    private static let maxMergedUtteranceSec: Double = 120

    /// Outcome of the «Я» detection: no owner cluster at all, a detected
    /// owner cluster, or a mic-dominant winner withheld because it
    /// confidently matches someone else (`vetoed` — the Center logs it; this
    /// enum is how the diagnostic escapes the pure layer without a print).
    enum SelfDetection: Equatable {
        case none
        case cluster(String)
        case vetoed(cluster: String, name: String)

        var clusterID: String? {
            if case .cluster(let id) = self { return id }
            return nil
        }
    }

    /// nil when roles cannot be derived (no segments / no speakers) — the
    /// caller then keeps the plain transcript text. The joined string is
    /// derived from `assign`'s structured utterances via the canonical
    /// renderer, so the two can never drift.
    static func render(
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String] = [:],
        ownerClusters: Set<String>? = nil,
        ownerVoiceAlike: Set<String> = []
    ) -> String? {
        assign(segments: segments, speakers: speakers, activity: activity,
               voiceNames: voiceNames, ownerClusters: ownerClusters,
               ownerVoiceAlike: ownerVoiceAlike)
            .map(TranscriptSegments.render)
    }

    /// Final label per cluster ID. Priority per cluster: mic dominance («Я»)
    /// → `voiceNames` (display names from confident voice-print matches) →
    /// dense "Speaker N" numbering over the remaining clusters in
    /// first-appearance order. Exposed so the save path can key the persisted
    /// per-cluster embeddings (`speakers_json`) by the same labels the
    /// transcript renders.
    ///
    /// `ownerClusters` (clusters whose WINNING voice match is a print of the
    /// machine's owner — identity from the connected Google accounts)
    /// refines «Я» for the meeting-room scenario where every voice comes
    /// through the owner's mic: (a) among several mic-dominant clusters the
    /// owner-matched one wins over the merely loudest; (b) a mic-dominant
    /// winner confidently matched to a colleague (a voice name WITHOUT owner
    /// match) is vetoed — colleagues' words must not render as the owner's.
    /// The veto needs at least two distinct clusters (a single-cluster
    /// recording is an under-split 1:1 — no signal to trust over the mic)
    /// and is suppressed for `ownerVoiceAlike` clusters (an owner print also
    /// matches them ≥ threshold, so "confidently someone else" does not
    /// hold; the owner-approved conservative rule — the alike set never
    /// PROMOTES a cluster to «Я», it only protects one from the veto).
    /// `ownerClusters` nil = owner identity unknown (no Google account, load
    /// failure) — mic dominance keeps its legacy absolute priority, a voice
    /// match can never claim the owner's cluster.
    static func clusterLabels(
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String] = [:],
        ownerClusters: Set<String>? = nil,
        ownerVoiceAlike: Set<String> = []
    ) -> [String: String] {
        let selfCluster = detectSelf(speakers: speakers, activity: activity,
                                     voiceNames: voiceNames, ownerClusters: ownerClusters,
                                     ownerVoiceAlike: ownerVoiceAlike).clusterID
        var labels: [String: String] = [:]
        var counter = 0
        for id in clusterOrder(speakers) {
            if id == selfCluster {
                labels[id] = selfLabel
            } else if let name = voiceNames[id], !name.isEmpty {
                labels[id] = name
            } else {
                counter += 1
                labels[id] = "Speaker \(counter)"
            }
        }
        return labels
    }

    /// Structured form of `render`: the merged same-speaker utterances with
    /// their time ranges, ready to persist as `segments_json`. nil under the
    /// same conditions as `render`. `voiceNames` (cluster ID → display name,
    /// from voice-print matching) renames matched clusters; how «Я» and
    /// voice names interact is defined in `clusterLabels`' doc.
    static func assign(
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String] = [:],
        ownerClusters: Set<String>? = nil,
        ownerVoiceAlike: Set<String> = []
    ) -> [TranscriptUtterance]? {
        guard !segments.isEmpty, !speakers.isEmpty else { return nil }

        // Cluster order by first appearance drives Speaker 1..N numbering.
        let order = clusterOrder(speakers)

        // 1. Each transcript segment → cluster with the largest temporal
        //    overlap; no overlap → the previous segment's cluster.
        var assigned: [(segment: TranscriptSegment, cluster: String)] = []
        var previous = order[0]
        for segment in segments {
            var best: (id: String, overlap: Double)?
            for s in speakers {
                let overlap = min(segment.endSec, s.endSec) - max(segment.startSec, s.startSec)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (s.speakerID, overlap)
                }
            }
            let cluster = best?.id ?? previous
            assigned.append((segment, cluster))
            previous = cluster
        }

        // 2. Labels: «Я» → voice-matched names → numbered strangers.
        let labels = clusterLabels(speakers: speakers, activity: activity,
                                   voiceNames: voiceNames, ownerClusters: ownerClusters,
                                   ownerVoiceAlike: ownerVoiceAlike)

        // 3. Merge consecutive same-cluster segments into one utterance.
        var utterances: [TranscriptUtterance] = []
        var currentCluster: String?
        var currentTexts: [String] = []
        var currentStart = 0.0
        var currentEnd = 0.0
        func flush() {
            guard let cluster = currentCluster, !currentTexts.isEmpty else { return }
            // ?? is unreachable (every assigned cluster is seeded into labels
            // via clusterOrder) — it only spares a force unwrap.
            utterances.append(TranscriptUtterance(
                idx: utterances.count,
                startSec: currentStart,
                endSec: currentEnd,
                speaker: labels[cluster] ?? cluster,
                text: currentTexts.joined(separator: " ")))
        }
        for (segment, cluster) in assigned {
            if cluster != currentCluster {
                flush()
                currentCluster = cluster
                currentTexts = []
                currentStart = segment.startSec
            } else if !currentTexts.isEmpty, segment.endSec - currentStart > maxMergedUtteranceSec {
                flush()
                currentTexts = []
                currentStart = segment.startSec
            }
            currentTexts.append(segment.text)
            currentEnd = segment.endSec
        }
        flush()
        return utterances
    }

    /// First-appearance order of cluster IDs — drives Speaker 1..N numbering
    /// and the earliest-wins tie determinism.
    private static func clusterOrder(_ speakers: [SpeakerSegment]) -> [String] {
        var order: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) where !order.contains(s.speakerID) {
            order.append(s.speakerID)
        }
        return order
    }

    /// The cluster whose speech time is dominated by the mic channel — the
    /// machine's owner. `.none` without an activity sidecar or when no
    /// cluster clears the threshold (then every speaker stays a numbered
    /// stranger); `.vetoed` when the winner was withheld (see
    /// `clusterLabels`' doc for the full semantics). Ties break toward the
    /// earliest cluster for determinism. Internal so the Center can ask "was
    /// the veto the reason there is no «Я»?" exactly once for its diagnostic
    /// log — this layer stays print-free.
    static func detectSelf(
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String],
        ownerClusters: Set<String>?,
        ownerVoiceAlike: Set<String> = []
    ) -> SelfDetection {
        guard let activity else { return .none }
        let order = clusterOrder(speakers)
        var stats: [String: (dominated: Int, total: Int)] = [:]
        for s in speakers {
            var t = s.startSec
            while t < s.endSec {
                if let bin = activity.bin(at: t) {
                    var entry = stats[s.speakerID] ?? (0, 0)
                    entry.total += 1
                    if bin.mic > bin.sys * micDominanceFactor {
                        entry.dominated += 1
                    }
                    stats[s.speakerID] = entry
                }
                t += MicActivity.binDuration
            }
        }
        var candidates: [(id: String, share: Double)] = []
        for id in order {
            guard let entry = stats[id], entry.total > 0 else { continue }
            let share = Double(entry.dominated) / Double(entry.total)
            if share > selfShareThreshold { candidates.append((id, share)) }
        }
        // Max share; strict > keeps the earliest on ties (candidates are in
        // first-appearance order).
        func loudest(_ xs: [(id: String, share: Double)]) -> String? {
            var best: (id: String, share: Double)?
            for c in xs where c.share > (best?.share ?? 0) { best = c }
            return best?.id
        }
        guard let best = loudest(candidates) else { return .none }
        guard let ownerClusters else { return .cluster(best) }
        // Tie-break: an owner-voice-matched candidate beats a louder one;
        // several owner matches (owner split across clusters) → max share.
        if let owner = loudest(candidates.filter { ownerClusters.contains($0.id) }) {
            return .cluster(owner)
        }
        if order.count >= 2, // a single cluster is an under-split 1:1 — no veto
           !ownerVoiceAlike.contains(best),
           let name = voiceNames[best], !name.isEmpty {
            return .vetoed(cluster: best, name: name)
        }
        return .cluster(best)
    }
}
