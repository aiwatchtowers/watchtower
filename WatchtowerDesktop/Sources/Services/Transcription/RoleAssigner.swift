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

    /// nil when roles cannot be derived (no segments / no speakers) — the
    /// caller then keeps the plain transcript text. The joined string is
    /// derived from `assign`'s structured utterances via the canonical
    /// renderer, so the two can never drift.
    static func render(
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String] = [:],
        ownerClusters: Set<String>? = nil
    ) -> String? {
        assign(segments: segments, speakers: speakers, activity: activity,
               voiceNames: voiceNames, ownerClusters: ownerClusters)
            .map(TranscriptSegments.render)
    }

    /// Final label per cluster ID. Priority per cluster: mic dominance («Я»)
    /// → `voiceNames` (display names from confident voice-print matches) →
    /// dense "Speaker N" numbering over the remaining clusters in
    /// first-appearance order. Exposed so the save path can key the persisted
    /// per-cluster embeddings (`speakers_json`) by the same labels the
    /// transcript renders.
    ///
    /// `ownerClusters` (clusters whose embedding confidently matches a voice
    /// print of the machine's OWNER — identity from the connected Google
    /// accounts) refines «Я» for the meeting-room scenario where every voice
    /// comes through the owner's mic: (a) among several mic-dominant clusters
    /// the owner-matched one wins over the merely loudest; (b) a mic-dominant
    /// winner confidently matched to a colleague (a voice name WITHOUT owner
    /// match) is vetoed — colleagues' words must not render as the owner's.
    /// nil = owner identity unknown (no Google account, load failure) — mic
    /// dominance keeps its legacy absolute priority, a voice match can never
    /// claim the owner's cluster.
    static func clusterLabels(
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        voiceNames: [String: String] = [:],
        ownerClusters: Set<String>? = nil
    ) -> [String: String] {
        var clusterOrder: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) where !clusterOrder.contains(s.speakerID) {
            clusterOrder.append(s.speakerID)
        }
        let selfCluster = detectSelfCluster(speakers: speakers, activity: activity, order: clusterOrder,
                                            voiceNames: voiceNames, ownerClusters: ownerClusters)
        var labels: [String: String] = [:]
        var counter = 0
        for id in clusterOrder {
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
        ownerClusters: Set<String>? = nil
    ) -> [TranscriptUtterance]? {
        guard !segments.isEmpty, !speakers.isEmpty else { return nil }

        // Cluster order by first appearance drives Speaker 1..N numbering.
        var clusterOrder: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) where !clusterOrder.contains(s.speakerID) {
            clusterOrder.append(s.speakerID)
        }

        // 1. Each transcript segment → cluster with the largest temporal
        //    overlap; no overlap → the previous segment's cluster.
        var assigned: [(segment: TranscriptSegment, cluster: String)] = []
        var previous = clusterOrder[0]
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
                                   voiceNames: voiceNames, ownerClusters: ownerClusters)

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

    /// The cluster whose speech time is dominated by the mic channel — the
    /// machine's owner. nil without an activity sidecar or when no cluster
    /// clears the threshold (then every speaker stays a numbered stranger).
    /// Ties break toward the earliest cluster in `order` for determinism.
    /// The «Я» vs owner-voice semantics (`ownerClusters` tri-state) are
    /// defined in `clusterLabels`' doc.
    private static func detectSelfCluster(
        speakers: [SpeakerSegment],
        activity: MicActivity?,
        order: [String],
        voiceNames: [String: String],
        ownerClusters: Set<String>?
    ) -> String? {
        guard let activity else { return nil }
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
        // `order`).
        func loudest(_ xs: [(id: String, share: Double)]) -> String? {
            var best: (id: String, share: Double)?
            for c in xs where c.share > (best?.share ?? 0) { best = c }
            return best?.id
        }
        guard let ownerClusters else { return loudest(candidates) }
        // Tie-break: an owner-voice-matched candidate beats a louder one;
        // several owner matches (owner split across clusters) → max share.
        if let owner = loudest(candidates.filter { ownerClusters.contains($0.id) }) {
            return owner
        }
        guard let best = loudest(candidates) else { return nil }
        if let name = voiceNames[best], !name.isEmpty {
            // The veto silently removing «Я» would look like mic detection
            // randomly stopped working (the mega-cluster suppression
            // precedent) — say why.
            print("[RoleAssigner] «Я» veto: mic-dominant cluster \(best) confidently matches \"\(name)\", not the owner — no «Я» in this transcript")
            return nil
        }
        return best
    }
}
